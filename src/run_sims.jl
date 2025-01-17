
using LinearAlgebra
using StatsBase
using Random
using Printf
using JLD2
using ProgressMeter

using POMDPs
using POMDPTools
using RockSample
using TagPOMDPProblem

using SparseArrays: sparsevec
using SparseArrays: SparseVector
using StaticArrays: SVector

# To visualize RockSample
using Cairo
using Fontconfig

include("constants.jl")
include("utils.jl")
include("suggestion_as_observation_update.jl")



"""
    run_sim(; kwargs...)

Runs simlulations and reports key metrics

# Arguments
- `problem::Symbol`: Problem to simulate (see RS_PROBS and TG_PROBS for options)

# Keword Arguments
- `num_steps::Int=50`: number of steps in each simulation
- `num_sims::Int=1`: number of simlulations to run
- `verbose::Bool=false`: print out details of each step
- `visualize::Bool=false`: render the environment at each step (2x per step)
- `agent::Symbol=:normal`: Which agent to simulate (see AGENTS for options)
- `ν=1.0`: hyperparameter for the naive agent (percent of suggestions to follow)
- `τ=1.0`: hyperparameter for the scaled agent
- `λ=1.0`: hyperparameter for the noisy agent
- `max_suggestions=Inf`: Limit of the number of suggestions the agent can receive
- `msg_reception_rate=1.0`: Recption rate of the agent for suggetsions
- `perfect_v_random=1.0`: Rate of perfect vs random suggestions (1.0=perfect, 0.0=random)
- `init_rocks=nothing`: For RockSamplePOMDP only. Designate the state of initial rocks. Must
be a vector with length equal to the number of rocks (e.g. [1, 0, 0, 1])
- `suggester_belief=[1.0, 0.0]`: RockSamplePOMDP only. Designate the iniital belief over
good rocks and bad rocks respectively. [1.0, 0.0] = perfect knowledge suggester,
[0.75, 0.5] would represent a suggester with a bit more knowledge over good rocks but no
additional information for the bad rocks.
- `init_pos=nothing`: TagPOMDP only. Set the iniital positions of the agent and opponent.
The form is Vector{Tuple{Int, Int}}. E.g. [(1, 1), (5, 2)].
- `rng=Random.GLOBAL_RNG`: Provide a random number generator
"""
function run_sim(
    problem::Symbol;
    num_steps::Int=50,
    num_sims::Int=1,
    verbose::Bool=false,
    visualize::Bool=false,
    agent::Symbol=:normal,
    ν=1.0,
    τ=1.0,
    λ=1.0,
    max_suggestions=Inf,
    msg_reception_rate=1.0,
    perfect_v_random=1.0,
    init_rocks=nothing,
    suggester_belief=[1.0, 0.0],
    init_pos=nothing,
    rng=Random.GLOBAL_RNG
)
    problem in RS_PROBS || problem in TG_PROBS || error("Invalid problem: $problem")
    agent in AGENTS || error("Invalid agent: $agent")

    pomdp, policy, load_str = get_problem_and_policy(problem)
    state_list = [pomdp...]
    num_states = length(pomdp)

    if problem in RS_PROBS
        num_rocks = length(pomdp.rocks_positions)
    end

    Q = Matrix{Float64}(undef, num_states, length(actions(pomdp)))
    if agent == :noisy
        Q_str = load_str * "_Q.jld2"
        @load(Q_str, Q)
    end

    r_vec = Vector{Float64}(undef, num_sims)
    sug_vec = Vector{Int}(undef, num_sims)
    step_vec = Vector{Int}(undef, num_sims)

    p = Progress(num_sims; desc="Running Simulations", barlen=50, showspeed=true)
    Threads.@threads for ijk = 1:num_sims
    # for ijk = 1:num_sims

        policy_sugg = deepcopy(policy)
        policy_agent = deepcopy(policy)

        belief_updater_sugg = updater(policy_sugg)
        belief_updater_agent = updater(policy_agent)

        # Get iniital state
        sᵢ = rand(rng, initialstate(pomdp))
        if problem in RS_PROBS && !isnothing(init_rocks)
            length(init_rocks) == num_rocks || error("Invalid init_rocks: $init_rocks")
            sᵢ = RSState{num_rocks}(pomdp.init_pos, init_rocks)
        elseif problem in TG_PROBS && !isnothing(init_pos)
            length(init_pos) == 2 || error("Invalid init_pos: $init_pos")
            sᵢ = TagState(init_pos[1], init_pos[2], false)
        end

        # Get the suggester init belief for simulation ijk
        if problem in RS_PROBS # In an RS problem, the user can specify beliefs over rocks
            suggester_belief_t = zeros(Float64, num_rocks)
            if length(suggester_belief) == num_rocks
                suggester_belief_t = copy(suggester_belief)
            else
                length(suggester_belief) == 2 || error("Incorrect suggester belief length")
                for (ii, rock_i) in enumerate(sᵢ.rocks)
                    if rock_i == 1
                        suggester_belief_t[ii] = suggester_belief[1]
                    else
                        suggester_belief_t[ii] = suggester_belief[2]
                    end
                end
            end
            suggester_b = initialbelief(pomdp, suggester_belief_t)
        else # In a TAG problem, so set the suggester belief to perfect knowledge
            suggester_b = SparseCat([sᵢ], [1.0])
        end

        bᵢ = beliefvector(pomdp, num_states, initialstate(pomdp))
        bₛ = beliefvector(pomdp, num_states, suggester_b)

        suggestion_cnt = 0
        step_cnt = 0
        total_reward = 0.0
        for kk = 1:num_steps
            step_cnt += 1
            t = kk # Sim time
            bₒ = bᵢ # Original belief before any updates
            a_n = action(policy_agent, bᵢ) # Action based on current belief
            a_p = action_known_state(policy_sugg, stateindex(pomdp, sᵢ)) # Perfect state belief

            # Get the suggested action
            if agent in [:naive, :scaled, :noisy]
                if rand(rng) <= perfect_v_random
                    if problem in RS_PROBS
                        suggestion = action(policy_sugg, bₛ)
                    else
                        suggestion = a_p # For Tag, suggester has perfect knowledge
                    end
                else
                    suggestion = rand(rng, actions(pomdp))
                end
            else
                suggestion = a_n
            end

            # Show depiction of state
            if visualize
                step = (s=sᵢ, a=a_n, b=belief_sparse(bᵢ, state_list))
                display(render(pomdp, step; pre_act_text="Pre oˢ: "))
            end

            # Suggested action ≠ normal action, update belief and pick new action
            if ((a_n != suggestion) &&
                (suggestion_cnt < max_suggestions) && # Haven't reached max suggestions
                (rand(rng) <= msg_reception_rate)) # Factor in reception rate

                suggestion_cnt += 1 # Increment suggestion count, we are processing it
                b′ = update_as_obs(agent, state_list, policy, bᵢ, suggestion, Q, τ, λ)
                if agent == :naive
                    if rand(rng) <= ν
                        a′ = suggestion
                    else
                        a′ = a_n
                    end
                else
                    a′ = action(policy_agent, b′)
                end
            else
                b′ = bᵢ
                a′ = a_n
            end

            # a is exectued action. Select based on agent type
            if agent == :normal
                a = a_n
            elseif agent == :perfect
                a = a_p
            elseif agent == :random
                a = rand(rng, actions(pomdp))
            elseif agent in [:naive, :scaled, :noisy]
                a = a′
                bᵢ = b′
            end

            # Simulate a step forward with action `a` from state `sᵢ`
            (sp, o, r) = @gen(:sp, :o, :r)(pomdp, sᵢ, a, rng)

            if verbose
                println("--------------------------------")
                println("Time                     : $t")
                println("State                    : $sᵢ")
                println("Initial Action:          : $a_n")
                if agent in [:naive, :scaled, :noisy]
                    println("Suggested Action         : $suggestion")
                end
                println("Perfect Knowledge Action : $a_p")
                println("Selected Action          : $a")
                println("Next State               : $sp")
                println("Observation              : $o")
                println("Immediate Reward         : $r")
                println("Discounted Reward        : $(pomdp.discount_factor^(t-1)*r)")
                println()
                println("--- Initial Belief at t = $t ---")
                display(belief_sparse(bₒ, state_list))
                if agent in [:scaled, :noisy, :naive]
                    println("--- Suggester Belief at t = $t ---")
                    display(belief_sparse(bₛ, state_list))
                end
                if agent in [:scaled, :noisy] && a_n != suggestion
                    println("--- Updated Belief at t = $t ---")
                    display(belief_sparse(bᵢ, state_list))
                end
            end

            if !(bᵢ isa SparseCat)
                bᵢ = SparseCat(state_list, bᵢ)
            end
            if !(bₛ isa SparseCat)
                bₛ = SparseCat(state_list, bₛ)
            end

            if visualize
                step = (s=sᵢ, a=a, o=o, b=bᵢ)
                display(render(pomdp, step; pre_act_text="Post oˢ: "))
            end

            # Update agent's belief with observation from environment
            bᵢ′ = update(belief_updater_agent, bᵢ, a, o)
            bᵢ = beliefvector(pomdp, num_states, bᵢ′)

            # Update suggester belief with observation (not a factor if perfect knowledge)
            bₛ′ = update(belief_updater_sugg, bₛ, a, o)
            bₛ = beliefvector(pomdp, num_states, bₛ′)

            sᵢ = sp # Update state to transitioned to state
            total_reward += pomdp.discount_factor^(t - 1) * r

            if isterminal(pomdp, sᵢ)
                break
            end
        end

        r_vec[ijk] = total_reward
        step_vec[ijk] = step_cnt
        sug_vec[ijk] = suggestion_cnt
        next!(p)
    end

    r_ave = mean(r_vec)
    r_std = std(r_vec)
    r_std_err = r_std / sqrt(num_sims)
    step_ave = mean(step_vec)
    step_std = std(step_vec)
    step_std_err = step_std / sqrt(num_sims)
    sug_ave = mean(sug_vec)
    sug_std = std(sug_vec)
    sug_std_err = sug_std / sqrt(num_sims)
    sug_p_step_vec = sug_vec ./ step_vec
    sug_p_step_ave = mean(sug_p_step_vec)
    sug_p_step_std = std(sug_p_step_vec)
    sug_p_step_std_err = sug_p_step_std / sqrt(num_sims)

    @printf("Agent: %s", agent)
    if agent == :naive
        @printf(", ν = %.2f", ν)
    elseif agent == :scaled
        @printf(", τ = %.2f", τ)
    elseif agent == :noisy
        @printf(", λ = %.2f", λ)
    end
    @printf("\n")
    @printf("%15s | %15s | %15s | %15s | %15s\n",
        "Metric", "Mean", "Standard Dev", "Standard Error", "+/- 95 CI")
    @printf("%15s | %15s | %15s | %15s | %15s\n",
        "---------------", "---------------", "---------------",
        "---------------", "---------------")
    @printf("%15s | %15.5f | %15.5f | %15.5f | %15.5f\n",
        "Reward", r_ave, r_std, r_std_err, 1.96 * r_std_err)
    @printf("%15s | %15.5f | %15.5f | %15.5f | %15.5f\n",
        "Steps", step_ave, step_std, step_std_err, 1.96 * step_std_err)
    @printf("%15s | %15.5f | %15.5f | %15.5f | %15.5f\n",
        "# Suggestions", sug_ave, sug_std, sug_std_err, 1.96 * sug_std_err)
    @printf("%15s | %15.5f | %15.5f | %15.5f | %15.5f\n",
        "# Sugg / Step", sug_p_step_ave, sug_p_step_std, sug_p_step_std_err,
        1.96 * sug_p_step_std_err)
end
