using ..ML_IMC

struct PreComputedInput
    nn_params::NeuralNetParameters
    system_params::SystemParameters
    reference_rdf::Vector{Float64}
end

struct ReferenceData
    distance_matrices::Vector{Matrix{Float64}}
    histograms::Vector{Vector{Float64}}
    pmf::Vector{Float64}
    g2_matrices::Vector{Matrix{Float64}}
    g3_matrices::Vector{Matrix{Float64}}
    g9_matrices::Vector{Matrix{Float64}}
end

function compute_pmf(rdf::AbstractVector{T},
                     system_params::SystemParameters)::Vector{T} where {T <: AbstractFloat}
    n_bins = system_params.n_bins
    β = system_params.beta

    # Initialize PMF array and identify repulsive regions
    pmf = Vector{T}(undef, n_bins)
    repulsion_mask = rdf .== zero(T)
    n_repulsion_points = count(repulsion_mask)

    # Calculate reference PMF values
    first_valid_index = n_repulsion_points + 1
    max_pmf = -log(rdf[first_valid_index]) / β
    next_pmf = -log(rdf[first_valid_index + 1]) / β
    pmf_gradient = max_pmf - next_pmf

    # Fill PMF array
    @inbounds for i in eachindex(pmf)
        if repulsion_mask[i]
            # Extrapolate PMF in repulsive region
            pmf[i] = max_pmf + pmf_gradient * (first_valid_index - i)
        else
            # Calculate PMF from RDF
            pmf[i] = -log(rdf[i]) / β
        end
    end

    return pmf
end

function precompute_reference_data(input::PreComputedInput;)::ReferenceData
    # Unpack input parameters
    nn_params = input.nn_params
    system_params = input.system_params
    ref_rdf = input.reference_rdf

    println("Pre-computing data for $(system_params.system_name)...")

    # Compute potential of mean force
    pmf = compute_pmf(ref_rdf, system_params)

    # Initialize trajectory reading
    trajectory = read_xtc(system_params)
    n_frames = Int(size(trajectory)) - 1  # Skip first frame

    # Pre-allocate data containers
    distance_matrices = Vector{Matrix{Float64}}(undef, n_frames)
    histograms = Vector{Vector{Float64}}(undef, n_frames)
    g2_matrices = Vector{Matrix{Float64}}(undef, n_frames)
    g3_matrices = Vector{Matrix{Float64}}(undef, n_frames * (length(nn_params.g3_functions) > 0))
    g9_matrices = Vector{Matrix{Float64}}(undef, n_frames * (length(nn_params.g9_functions) > 0))

    # Process each frame
    for frame_id in 1:n_frames
        frame = read_step(trajectory, frame_id)
        box = lengths(UnitCell(frame))
        coords = positions(frame)

        # Compute distance matrix and histogram
        distance_matrices[frame_id] = build_distance_matrix(frame)
        histograms[frame_id] = zeros(Float64, system_params.n_bins)
        update_distance_histogram!(distance_matrices[frame_id], histograms[frame_id], system_params)

        # Compute symmetry function matrices
        g2_matrices[frame_id] = build_g2_matrix(distance_matrices[frame_id], nn_params)

        if !isempty(nn_params.g3_functions)
            g3_matrices[frame_id] = build_g3_matrix(distance_matrices[frame_id], coords, box, nn_params)
        end

        if !isempty(nn_params.g9_functions)
            g9_matrices[frame_id] = build_g9_matrix(distance_matrices[frame_id], coords, box, nn_params)
        end
    end

    return ReferenceData(distance_matrices,
                         histograms,
                         pmf,
                         g2_matrices,
                         g3_matrices,
                         g9_matrices)
end

function compute_pretraining_gradient(energy_diff_nn::T,
                                      energy_diff_pmf::T,
                                      symm_func_matrix1::AbstractMatrix{T},
                                      symm_func_matrix2::AbstractMatrix{T},
                                      model::Chain,
                                      pretrain_params::PreTrainingParameters,
                                      nn_params::NeuralNetParameters;
                                      log_file::String="pretraining-loss-values.out",
                                      verbose::Bool=false) where {T <: AbstractFloat}
    # Calculate MSE loss between energy differences
    mse_loss = (energy_diff_nn - energy_diff_pmf)^2

    # Log loss value
    try
        open(log_file, "a") do io
            println(io, round(mse_loss; digits=8))
        end
    catch e
        @warn "Failed to write to log file: $log_file" exception=e
    end

    # Calculate regularization loss
    model_params = Flux.params(model)
    reg_loss = pretrain_params.regularization * sum(abs2, model_params[1])

    # Print detailed loss information if requested
    if verbose
        println("""
           Energy loss: $(round(mse_loss; digits=8))
           PMF energy difference: $(round(energy_diff_pmf; digits=8))
           NN energy difference: $(round(energy_diff_nn; digits=8))
           Regularization loss: $(round(reg_loss; digits=8))
        """)
    end

    # Compute gradients for both configurations
    grad1 = compute_energy_gradients(symm_func_matrix1, model, nn_params)
    grad2 = compute_energy_gradients(symm_func_matrix2, model, nn_params)

    # Calculate loss gradients with regularization
    gradient_scale = 2 * (energy_diff_nn - energy_diff_pmf)
    loss_gradient = @. gradient_scale * (grad2 - grad1)
    reg_gradient = @. model_params * 2 * pretrain_params.regularization

    return loss_gradient + reg_gradient
end

function pretraining_move!(reference_data::ReferenceData, model::Flux.Chain, nn_params::NeuralNetParameters,
                           system_params::SystemParameters, rng::Xoroshiro128Plus)
    # Pick a frame
    traj = read_xtc(system_params)
    nframes = Int(size(traj)) - 1 # Don't take the first frame
    frame_id::Int = rand(rng, 1:nframes)
    frame = read_step(traj, frame_id)
    box = lengths(UnitCell(frame))
    # Pick a particle
    point_index::Int = rand(rng, 1:(system_params.n_atoms))

    # Read reference data
    distance_matrix = reference_data.distance_matrices[frame_id]
    hist = reference_data.histograms[frame_id]
    pmf = reference_data.pmf

    # If no angular symmetry functions are provided, use G2 only
    if isempty(reference_data.g3_matrices) && isempty(reference_data.g9_matrices)
        symm_func_matrix1 = reference_data.g2_matrices[frame_id]
    else
        # Make a copy of the original coordinates
        coordinates1 = copy(positions(frame))
        # Combine symmetry function matrices
        if isempty(reference_data.g3_matrices)
            symm_func_matrices = [reference_data.g2_matrices[frame_id], reference_data.g9_matrices[frame_id]]
        elseif isempty(reference_data.g9_matrices)
            symm_func_matrices = [reference_data.g2_matrices[frame_id], reference_data.g3_matrices[frame_id]]
        else
            symm_func_matrices = [
                reference_data.g2_matrices[frame_id],
                reference_data.g3_matrices[frame_id],
                reference_data.g9_matrices[frame_id]
            ]
        end
        # Unpack symmetry functions and concatenate horizontally into a single matrix
        symm_func_matrix1 = hcat(symm_func_matrices...)
    end

    # Compute energy of the initial configuration
    e_nn1_vector = init_system_energies_vector(symm_func_matrix1, model)
    e_nn1 = sum(e_nn1_vector)
    e_pmf1 = sum(hist .* pmf)

    # Allocate the distance vector
    distance_vector1 = distance_matrix[:, point_index]

    # Displace the particle
    dr = system_params.max_displacement * (rand(rng, Float64, 3) .- 0.5)

    positions(frame)[:, point_index] .+= dr

    # Compute the updated distance vector
    point = positions(frame)[:, point_index]
    distance_vector2 = compute_distance_vector(point, positions(frame), box)

    # Update the histogram
    hist = update_distance_histogram_vectors!(hist, distance_vector1, distance_vector2, system_params)

    # Get indexes for updating ENN
    indexes_for_update = get_energies_update_mask(distance_vector2, nn_params)

    # Make a copy of the original G2 matrix and update it
    g2_matrix2 = copy(reference_data.g2_matrices[frame_id])
    update_g2_matrix!(g2_matrix2, distance_vector1, distance_vector2, system_params, nn_params, point_index)

    # Make a copy of the original angular matrices and update them
    g3_matrix2 = []
    if !isempty(reference_data.g3_matrices)
        g3_matrix2 = copy(reference_data.g3_matrices[frame_id])
        update_g3_matrix!(g3_matrix2, coordinates1, positions(frame), box, distance_vector1, distance_vector2,
                          system_params,
                          nn_params, point_index)
    end

    # Make a copy of the original angular matrices and update them
    g9_matrix2 = []
    if !isempty(reference_data.g9_matrices)
        g9_matrix2 = copy(reference_data.g9_matrices[frame_id])
        update_g9_matrix!(g9_matrix2, coordinates1, positions(frame), box, distance_vector1, distance_vector2,
                          system_params,
                          nn_params, point_index)
    end

    # Combine symmetry function matrices accumulators
    symm_func_matrix2 = combine_symmetry_matrices(g2_matrix2, g3_matrix2, g9_matrix2)

    # Compute the NN energy again
    e_nn2_vector = update_system_energies_vector(symm_func_matrix2, model, indexes_for_update, e_nn1_vector)
    e_nn2 = sum(e_nn2_vector)
    e_pmf2 = sum(hist .* pmf)

    # Get the energy differences
    Δe_nn = e_nn2 - e_nn1
    Δe_pmf = e_pmf2 - e_pmf1

    # Revert the changes in the frame arrays
    positions(frame)[:, point_index] .-= dr
    hist = update_distance_histogram_vectors!(hist, distance_vector2, distance_vector1, system_params)

    return (symm_func_matrix1, symm_func_matrix2, Δe_nn, Δe_pmf)
end

function pretrain_model!(pretrain_params::PreTrainingParameters,
                         nn_params::NeuralNetParameters,
                         system_params_list,
                         model::Chain,
                         optimizer::Flux.Optimise.AbstractOptimiser,
                         reference_rdfs;
                         save_path::String="model-pre-trained.bson",
                         verbose::Bool=true)::Chain

    # Initialize random number generator and prepare reference data
    rng = RandomNumbers.Xorshifts.Xoroshiro128Plus()
    n_systems = length(system_params_list)

    # Prepare inputs for parallel computation
    ref_data_inputs = [PreComputedInput(nn_params, system_params_list[i], reference_rdfs[i])
                       for i in 1:n_systems]

    # Pre-compute reference data in parallel
    ref_data_list = pmap(precompute_reference_data, ref_data_inputs)

    # Main training loop
    for step in 1:(pretrain_params.steps)
        should_report = (step % pretrain_params.output_frequency == 0) || (step == 1)
        if should_report && verbose
            println("\nPre-training step: $step")
        end

        # Compute gradients for all systems
        loss_gradients = Vector{Any}(undef, n_systems)
        for sys_id in 1:n_systems
            ref_data = ref_data_list[sys_id]

            # Get energy differences and matrices for current system
            symm_func_matrix1, symm_func_matrix2, Δe_nn, Δe_pmf = pretraining_move!(ref_data,
                                                                                    model,
                                                                                    nn_params,
                                                                                    system_params_list[sys_id],
                                                                                    rng)

            # Calculate gradient for current system
            loss_gradients[sys_id] = compute_pretraining_gradient(Δe_nn,
                                                                  Δe_pmf,
                                                                  symm_func_matrix1,
                                                                  symm_func_matrix2,
                                                                  model,
                                                                  pretrain_params,
                                                                  nn_params,
                                                                  verbose=should_report)
        end

        # Update model with mean gradients
        mean_gradients = mean(loss_gradients)
        update_model!(model, optimizer, mean_gradients)
    end

    # Save trained model
    try
        @save save_path model
        check_file(save_path)
        verbose && println("\nModel saved to $save_path")
    catch e
        @warn "Failed to save model to $save_path" exception=e
    end

    return model
end
