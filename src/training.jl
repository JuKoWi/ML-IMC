using ..ML_IMC

function compute_training_loss(descriptor_nn::AbstractVector{T},
                               descriptor_ref::AbstractVector{T},
                               model::Flux.Chain,
                               nn_params::NeuralNetParameters) where {T <: AbstractFloat}

    # Compute descriptor difference loss
    descriptor_loss_se = sum(abs2, descriptor_nn .- descriptor_ref)
    descriptor_loss_mse = mean(abs2, descriptor_nn .- descriptor_ref)

    # Compute L1 regularization loss if regularization parameter is positive
    reg_loss = zero(T)
    if nn_params.regularization > zero(T)
        reg_loss = nn_params.regularization * sum(sum(abs, p) for p in Flux.params(model))
    end

    total_loss_se = descriptor_loss_se + reg_loss
    total_loss_mse = descriptor_loss_mse + reg_loss

    println("    Losses:")
    for (label, value) in [
        ("        Regularization:", reg_loss),
        ("        Descriptor:    ", descriptor_loss_se),
        ("        Squared Error: ", total_loss_se),
        ("        MSE:           ", total_loss_mse)
    ]
        println("$label = $(round(value; digits=8))")
    end
    println()

    # Log descriptor loss to file
    LOSS_LOG_FILE = "training-loss-values.out"
    try
        open(LOSS_LOG_FILE, "a") do io
            println(io, round(descriptor_loss_mse; digits=8))
        end
        check_file(LOSS_LOG_FILE)
    catch e
        @warn "Failed to log loss value" exception=e
    end

    return total_loss_se, total_loss_mse
end

function prepare_monte_carlo_inputs(global_params::GlobalParameters,
                                    mc_params::MonteCarloParameters,
                                    nn_params::NeuralNetParameters,
                                    system_params_list::Vector{SystemParameters},
                                    model::Flux.Chain)
    n_systems = length(system_params_list)
    n_workers = nworkers()

    # Validate that workers can be evenly distributed across systems
    if n_workers % n_systems != 0
        throw(ArgumentError("Number of workers ($n_workers) must be divisible by number of systems ($n_systems)"))
    end

    # Create input for each system
    reference_inputs = Vector{MonteCarloSampleInput}(undef, n_systems)
    for (i, system_params) in enumerate(system_params_list)
        reference_inputs[i] = MonteCarloSampleInput(global_params,
                                                    mc_params,
                                                    nn_params,
                                                    system_params,
                                                    model)
    end

    # Replicate inputs for all workers
    sets_per_system = n_workers ÷ n_systems
    return repeat(reference_inputs, sets_per_system)
end

function train!(global_params::GlobalParameters,
                mc_params::MonteCarloParameters,
                nn_params::NeuralNetParameters,
                system_params_list::Vector{SystemParameters},
                model::Flux.Chain,
                optimizer::Flux.Optimise.AbstractOptimiser,
                ref_rdfs)
    for iteration in 1:(nn_params.iterations)
        iter_string = lpad(iteration, 2, "0")
        println("\nIteration $iteration")
        println("~~~~~~~~~~~~")

        # Monte Carlo sampling
        inputs = prepare_monte_carlo_inputs(global_params, mc_params, nn_params, system_params_list, model)
        outputs = pmap(mcsample!, inputs)

        # Process system outputs and compute losses
        system_outputs, system_losses = collect_system_averages(outputs, ref_rdfs, system_params_list, global_params,
                                                                nn_params, model)

        # Compute gradients for each system
        loss_gradients = Vector{Any}(undef, length(system_outputs))
        for (system_id, system_output) in enumerate(system_outputs)
            system_params = system_params_list[system_id]

            loss_gradients[system_id] = compute_loss_gradients(system_output.cross_accumulators,
                                                               system_output.symmetry_matrix_accumulator,
                                                               system_output.descriptor,
                                                               ref_rdfs[system_id],
                                                               model,
                                                               system_params,
                                                               nn_params)

            # Save system outputs
            name = system_params.system_name
            write_rdf("RDFNN-$(name)-iter-$(iter_string).dat", system_output.descriptor, system_params)
            write_energies("energies-$(name)-iter-$(iter_string).dat",
                           system_output.energies,
                           mc_params,
                           system_params,
                           1)
        end

        # Compute mean loss gradients
        mean_loss_gradients = if global_params.adaptive_scaling
            gradient_coeffs = compute_adaptive_gradient_coefficients(system_losses)

            println("\nGradient scaling:")
            for (coeff, params) in zip(gradient_coeffs, system_params_list)
                println("   System $(params.system_name): $(round(coeff; digits=8))")
            end

            sum(loss_gradients .* gradient_coeffs)
        else
            mean(loss_gradients)
        end

        # Save model state
        @save "model-iter-$(iter_string).bson" model
        check_file("model-iter-$(iter_string).bson")
        @save "opt-iter-$(iter_string).bson" optimizer
        check_file("opt-iter-$(iter_string).bson")
        @save "gradients-iter-$(iter_string).bson" mean_loss_gradients
        check_file("gradients-iter-$(iter_string).bson")

        # Update model with computed gradients
        update_model!(model, optimizer, mean_loss_gradients)
    end

    println("Training completed!")
end
