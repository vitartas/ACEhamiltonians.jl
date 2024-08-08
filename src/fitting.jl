module Fitting
using HDF5, ACE, ACEbase, ACEhamiltonians, StaticArrays, Statistics, LinearAlgebra, SparseArrays, IterativeSolvers
using ACEfit: linear_solve, SKLEARN_ARD, SKLEARN_BRR
using HDF5: Group
using JuLIP: Atoms
using ACE: ACEConfig, evaluate, scaling, AbstractState, SymmetricBasis
using ACEhamiltonians.Common: number_of_orbitals
using ACEhamiltonians.Bases: envelope
using ACEhamiltonians.DatabaseIO: load_hamiltonian_gamma, load_overlap_gamma
using ACEatoms:AtomicNumber
using LowRankApprox: pqrfact

using ACEhamiltonians: DUAL_BASIS_MODEL


export fit!

# set abs(a::AtomicNumber) = 0 as it is called in the `scaling` function but should not change the output
Base.abs(a::AtomicNumber) = 0 # a.z

# Once the bond inversion issue has been resolved the the redundant models will no longer
# be required. The changes needed to be made in this file to remove the redundant model
# are as follows:
#   - Remove inverted state condition in single model `fit!` method.
#   - `_assemble_ls` should take `AHSubModel` entities.
#   - Remove inverted state condition from the various `predict` methods.

# Todo:
#   - Need to make sure that the acquire_B! function used by ACE does not actually modify the
#     basis function. Otherwise there may be some issues with sharing basis functions.
#   - ACE should be modified so that `valtype` inherits from Base. This way there should be
#     no errors caused when importing it.
#   - Remove hard coded matrix type from the predict function.

# The _assemble_ls and _evaluate_real methods should be rewritten to use PseudoBlockArrays
# this will prevent redundant allocations from being made and will mean that _preprocessA
# and _preprocessY can also be removed. This should help speed up the code and should
# significantly improve memory usage.
function _preprocessA(A)
    # Note; this function was copied over from the original ACEhamiltonians/fit.jl file. 

    # S1: number of sites; S2: number of basis, SS1: 2L1+1, SS2: 2L2+1
    S1,S2 = size(A)
    SS1,SS2 = size(A[1])
    A_temp = zeros(ComplexF64, S1*SS1*SS2, S2)
    for i = 1:S1, j = 1:S2
        A_temp[SS1*SS2*(i-1)+1:SS1*SS2*i,j] = reshape(A[i,j],SS1*SS2,1)
    end
    return real(A_temp)
end
 
function _preprocessY(Y)
    # Note; this function was copied over from the original ACEhamiltonians/fit.jl file.

    Len = length(Y)
    SS1,SS2 = size(Y[1])
    Y_temp = zeros(ComplexF64,Len*SS1*SS2)
    for i = 1:Len
        Y_temp[SS1*SS2*(i-1)+1:SS1*SS2*i] = reshape(Y[i],SS1*SS2,1)
    end
    return real(Y_temp)
end


# NOTE: Changed the number of iterations
function solve_ls(A, Y, λ, Γ, solver = "LSQR"; niter = 100, inner_tol = 1e-3)
    # Note; this function was copied over from the original ACEhamiltonians/fit.jl file.

    A = _preprocessA(A)
    Y = _preprocessY(Y)
    
    num = size(A)[2]
    A = [A; λ*Γ]
    Y = [Y; zeros(num)]
    if solver == "QR"
       return real(qr(A) \ Y)
    elseif solver == "LSQR"
       # The use of distributed arrays is still causing a memory leak. As such the following
       # code has been disabled until further notice.
       # Ad, Yd = distribute(A), distribute(Y)
       # res = real(IterativeSolvers.lsqr(Ad, Yd; atol = 1e-6, btol = 1e-6))
       # close(Ad), close(Yd)
       res = real(IterativeSolvers.lsqr(A, Y; atol = 1e-6, btol = 1e-6))
       return res
    elseif solver == "ARD"
       return linear_solve(SKLEARN_ARD(;n_iter = niter, tol = inner_tol), A, Y)["C"]
    elseif solver == "BRR"
       return linear_solve(SKLEARN_BRR(;n_iter = niter, tol = inner_tol), A, Y)["C"]
    elseif solver == "RRQR"
       AP = A / I
       θP = pqrfact(A, rtol = inner_tol) \ Y
       return I \ θP
    elseif solver == "NaiveSolver"
       return real((A'*A) \ (A'*Y))
    end
 
 end


function _ctran(l::Int64,m::Int64,μ::Int64)
   if abs(m) ≠ abs(μ)
      return 0
   elseif abs(m) == 0
      return 1
   elseif m > 0 && μ > 0
      return 1/sqrt(2)
   elseif m > 0 && μ < 0
      return (-1)^m/sqrt(2)
   elseif m < 0 && μ > 0
      return  - im * (-1)^m/sqrt(2)
   else
      return im/sqrt(2)
   end
end

_ctran(l::Int64) = sparse(Matrix{ComplexF64}([ _ctran(l,m,μ) for m = -l:l, μ = -l:l ]))

function _evaluate_real(Aval)
   L1,L2 = size(Aval[1])
   L1 = Int((L1-1)/2)
   L2 = Int((L2-1)/2)
   C1 = _ctran(L1)
   C2 = _ctran(L2)
   return real([ C1 * Aval[i].val * C2' for i = 1:length(Aval)])
end

"""
"""
function _assemble_ls(basis::SymmetricBasis, data::T, enable_mean::Bool=false) where T<:AbstractFittingDataSet
    # This will be rewritten once the other code has been refactored.

    # Should `A` not be constructed using `acquire_B!`?

    n₁, n₂, n₃ = size(data)
    # Currently the code desires "A" to be an X×Y matrix of Nᵢ×Nⱼ matrices, where X is
    # the number of sub-block samples, Y is equal to `size(bos.basis.A2Bmap)[1]`, and
    # Nᵢ×Nⱼ is the sub-block shape; i.e. 3×3 for pp interactions. This may be refactored
    # at a later data if this layout is not found to be strictly necessary.
    cfg = ACEConfig.(data.states)
    # NOTE: evaluate. seems to not break stuff as long as m.c ∈ ℝ¹ = 1
    Aval = evaluate.(Ref(basis), cfg)
    # NOTE: why is _evaluate_real needed here?
    A = permutedims(reduce(hcat, _evaluate_real.(Aval)), (2, 1))
    
    Y = [data.values[:, :, i] for i in 1:n₃]

    # Calculate the mean value x̄
    if enable_mean && n₁ ≡ n₂ && ison(data) 
        x̄ = mean(diag(mean(Y)))*I(n₁)
    else
        x̄ = zeros(n₁, n₂)
    end

    Y .-= Ref(x̄)
    return A, Y, x̄

end


###################
# Fitting Methods #
###################

"""
    fit!(submodel, data;[ enable_mean])

Fits a specified model with the supplied data.

# Arguments
- `submodel`: a specified submodel that is to be fitted.
- `data`: data that the basis is to be fitted to.
- `enable_mean::Bool`: setting this flag to true enables a non-zero mean to be
   used.
- `λ::AbstractFloat`: regularisation term to be used (default=1E-7).
- `solver::String`: solver to be used (default="LSQR")
"""
function fit!(submodel::T₁, data::T₂; enable_mean::Bool=false, λ=1E-7, solver="LSQR") where {T₁<:AHSubModel, T₂<:AbstractFittingDataSet}

    # Get the basis function's scaling factor
    Γ = Diagonal(scaling(submodel.basis, 2))

    # Setup the least squares problem
    Φ, Y, x̄ = _assemble_ls(submodel.basis, data, enable_mean)
    
    # Assign the mean value to the basis set
    submodel.mean .= x̄

    # Solve the least squares problem and get the coefficients

    submodel.coefficients .= collect(solve_ls(Φ, Y, λ, Γ, solver))

    # NOTE: From the looks of it ps_ij is evaluated and fitted here.
    # As far as I understand, to evaluate ps_ji instead, we would need to define
    # a cyllindrical envelope with λ = 1.0 instead of λ = 0.0,
    # such that for basis and basis_i the expansion points would be flipped.
    @static if DUAL_BASIS_MODEL
        if T₁<:AnisoSubModel
            Γ = Diagonal(scaling(submodel.basis_i, 2))
            Φ, Y, x̄ = _assemble_ls(submodel.basis_i, data', enable_mean)
            submodel.mean_i .= x̄
            submodel.coefficients_i .= collect(solve_ls(Φ, Y, λ, Γ, solver))
        end
    end

    nothing
end


# Convenience function for appending data to a dictionary
function _append_data!(dict, key, value)
    if haskey(dict, key)
        dict[key] = dict[key] + value
    else
        dict[key] = value
    end
end



"""
    fit!(model, systems;[ on_site_filter, off_site_filter, tolerance, recentre, refit, target])

Fits a specified model to the supplied data.

# Arguments
- `model::Model`: Model to be fitted.
- `systems::Vector{Group}`: HDF5 groups storing data with which the model should
    be fitted.
- `on_site_filter::Function`: the on-site `DataSet` entities will be passed through this
    filter function prior to fitting; defaults `identity`.
- `off_site_filter::Function`: the off-site `DataSet` entities will be passed through this
    filter function prior to fitting; defaults `identity`.
- `tolerance::AbstractFloat`: only sub-blocks where at least one value is greater than
    or equal to `tolerance` will be fitted. This argument permits sparse blocks to be
    ignored.
- `recentre::Bool`: Enabling this will re-wrap atomic coordinates to be consistent with
    the geometry layout used internally by FHI-aims. This should be used whenever loading
    real-space matrices generated by FHI-aims.
- `refit::Bool`: By default already fitted bases will not be refitted, but this behaviour
    can be suppressed by setting `refit=true`.
- `target::String`: a string indicating which matrix should be fitted. This may be either
    `H` or `S`. If unspecified then the model's `.label` field will be read and used. 
"""
function fit!(
    model::Model, systems::Vector{Group};
    on_site_filter::Function = identity,
    off_site_filter::Function = identity,
    tolerance::Union{F, Nothing}=nothing,
    recentre::Bool=false, 
    target::Union{String, Nothing}=nothing, 
    refit::Bool=false, solver = "LSQR") where F<:AbstractFloat
    
    # Todo:
    #   - Add fitting parameters options which uses a `Params` instance to define fitting
    #     specific parameters such as regularisation, solver method, whether or not mean is
    #     used when fitting, and so on.
    #   - Modify so that redundant data is not extracted; i.e. both A[0,0,0] -> A[1,0,0] and
    #     A[0,0,0] -> A[-1,0,0]
    #   - The approach currently taken limits io overhead by reducing redundant operations.
    #     However, this will likely use considerably more memory.

    # Section 1: Gather the data

    # If no target has been specified; then default to that given by the model's label.
    
    target = isnothing(target) ? model.label : target

    get_matrix = Dict(  # Select an appropriate function to load the target matrix
        "H"=>load_hamiltonian, "S"=>load_overlap,
        "Hg"=>load_hamiltonian_gamma, "Sg"=>load_overlap_gamma)[target]

    fitting_data = Dict{Any, DataSet}()

    # Loop over the specified systems
    for system in systems

        # Load the required data from the database entry
        matrix, atoms = get_matrix(system), load_atoms(system; recentre=recentre)
        images = ndims(matrix) == 2 ? nothing : load_cell_translations(system)
        
        # Loop over the on site bases and collect the appropriate data
        for basis in values(model.on_site_submodels)
            data_set = get_dataset(matrix, atoms, basis, model.basis_definition, images;
                tolerance=tolerance)

            # Don't bother filtering and adding empty datasets 
            if length(data_set) != 0
                # Apply the on-site data filter function
                data_set = on_site_filter(data_set)
                # Add the selected data to the fitting data-set.
                _append_data!(fitting_data, basis.id, data_set)
            end
        end 

        # Repeat for the off-site models
        for basis in values(model.off_site_submodels)
            data_set = get_dataset(matrix, atoms, basis, model.basis_definition, images;
                tolerance=tolerance, filter_bonds=true)
        
            if length(data_set) != 0
                data_set = off_site_filter(data_set)
                _append_data!(fitting_data, basis.id, data_set)
            end

        end         
    end

    # Fit the on/off-site models
    fit!(model, fitting_data; refit=refit, solver = solver)
    
end


"""
    fit!(model, fitting_data[; refit])


Fit the specified model using the provided data.

# Arguments
- `model::Model`: the model that should be fitted.
- `fitting_data`: dictionary providing the data to which the supplied model should be
  fitted. This should hold one entry for each submodel that is to be fitted and should take
  the form `{SubModel.id, DataSet}`.
- `refit::Bool`: By default, already fitted bases will not be refitted, but this behaviour
  can be suppressed by setting `refit=true`.
"""
function fit!(
    model::Model, fitting_data; refit::Bool=false, solver="LSQR")

    @debug "Fitting off site bases:"
    for (id, basis) in model.off_site_submodels
        if !haskey(fitting_data, id)
            @debug "Skipping $(id): no fitting data provided"
        elseif is_fitted(basis) && !refit
            @debug "Skipping $(id): submodel already fitted"
        elseif length(fitting_data) ≡ 0
            @debug "Skipping $(id): fitting dataset is empty"
        else
            @debug "Fitting $(id): using $(length(fitting_data[id])) fitting points"
            # NOTE: each subblock is fitted separately, but some of them have the same basis functions,
            # which means if evaluations are not cached, then we end up evaluating the same basis functions
            # multiple times
            fit!(basis, fitting_data[id]; solver = solver)
        end    
    end

    @debug "Fitting on site bases:"
    for (id, basis) in model.on_site_submodels
        if !haskey(fitting_data, id)
            @debug "Skipping $(id): no fitting data provided"
        elseif is_fitted(basis) && !refit
            @debug "Skipping $(id): submodel already fitted"
        elseif length(fitting_data) ≡ 0
            @debug "Skipping $(id): fitting dataset is empty"
        else
            @debug "Fitting $(id): using $(length(fitting_data[id])) fitting points"
            fit!(basis, fitting_data[id]; enable_mean=ison(basis), solver = solver)
        end    
    end
end


# The following code was added to `fitting.jl` to allow data to be fitted on databases
# structured using the original database format.
using ACEhamiltonians.DatabaseIO: _load_old_atoms, _load_old_hamiltonian, _load_old_overlap
using Serialization

function old_fit!(
    model::Model, systems, target::Symbol;
    tolerance::F=0.0, filter_bonds::Bool=true, recentre::Bool=false,
    refit::Bool=false) where F<:AbstractFloat
    
    # Todo:
    #   - Check that the relevant data exists before trying to extract it; i.e. don't bother
    #     trying to gather carbon on-site data from an H2 system.
    #   - Currently the basis set definition is loaded from the first system under the
    #     assumption that it is constant across all systems. However, this will break down
    #     if different species are present in each system.
    #   - The approach currently taken limits io overhead by reducing redundant operations.
    #     However, this will likely use considerably more memory.

    # Section 1: Gather the data

    get_matrix = Dict(  # Select an appropriate function to load the target matrix
        :H=>_load_old_hamiltonian, :S=>_load_old_overlap)[target]

    fitting_data = IdDict{AHSubModel, DataSet}()

    # Loop over the specified systems
    for (database_path, index_data) in systems
        
        # Load the required data from the database entry
        matrix, atoms = get_matrix(database_path), _load_old_atoms(database_path)

        println("Loading: $database_path")

        # Loop over the on site bases and collect the appropriate data
        if haskey(index_data, "atomic_indices")
            println("Gathering on-site data:")
            for basis in values(model.on_site_submodels)
                println("\t- $basis")
                data_set = get_dataset(
                    matrix, atoms, basis, model.basis_definition;
                    tolerance=tolerance, focus=index_data["atomic_indices"])
                _append_data!(fitting_data, basis, data_set)
  
            end
            println("Finished gathering on-site data")
        end

        # Repeat for the off-site models
        if haskey(index_data, "atom_block_indices")
            println("Gathering off-site data:")
            for basis in values(model.off_site_submodels)
                println("\t- $basis")
                data_set = get_dataset(
                    matrix, atoms, basis, model.basis_definition;
                    tolerance=tolerance, filter_bonds=filter_bonds, focus=index_data["atom_block_indices"])
                _append_data!(fitting_data, basis, data_set)
            end
            println("Finished gathering off-site data")
        end
    end

    # Fit the on/off-site models
    fit!(model, fitting_data; refit=refit) 

end

end
