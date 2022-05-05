module SimplexSearch

using Statistics
using LinearAlgebra
using Random

function dataset(n::Int, p::Int)
    trainset = randn(n, p)
    trainlabels = rand((-1,1), p)
    return trainset, trainlabels
end

function energy(w::Vector, K::Int, trainset::Matrix, trainlabels::Vector)
    n = length(w)
    p = length(trainlabels)
    @assert n % K == 0
    @assert size(trainset) == (n, p)
    nh = n ÷ K # inputs per hidden unit

    W = reshape(w, nh, K)
    X = reshape(trainset, nh, K, p)
    # indices = Int[]
    errors = 0
    @inbounds for μ = 1:p
        Δ = 0
        for j = 1:K
            Δj = 0.0
            for i = 1:nh
                Δj += W[i, j] * X[i, j, μ]
            end
            Δ += sign(Δj)
        end
        outμ = sign(Δ)
        if outμ ≠ trainlabels[μ]
            # push!(indices, μ)
            errors += 1
        end
    end

    ## vectorized broadcasted version: slower than the explicit for loops, and allocates
    ## TODO? try Tullio.jl

    # errors2 = sum(vec(sign.(sum(sign.(sum(W .* X, dims=1)), dims=2))) .≠ trainlabels)
    # @assert errors == errors2

    # println("error indices: $indices")
    return errors
end

function gen_candidate(
        ps::Matrix,           # input points (in a matrix, each column is a point)
        vsum::Vector,         # sum of all the points
        i_sub::Int,         # index of the point to substitute
        d::Float64,           # pairwise points distance
        trainset::Matrix,
        trainlabels::Vector,
        K::Int = 3,
    )
    n, y = size(ps)
    @assert y ≥ 2
    @assert 1 ≤ i_sub ≤ y

    p_old = ps[:,i_sub]

    ## barycenter, excluding the point to be removed
    vcav = vsum - p_old
    ccav = vcav / (y - 1)

    ## distance from barycenter (expected)
    ρ = d * norm(ccav) / √(1 - d^2 / 2) * √(y / (2*(y - 1)))

    ## generate a new random direction
    x = ρ / √n * randn(n)

    ## choose the best of the two directions
    p_new1 = ccav + x
    p_new2 = ccav - x
    E_new1 = energy(p_new1, K, trainset, trainlabels)
    E_new2 = energy(p_new2, K, trainset, trainlabels)
    ## new point
    p_new, E_new = E_new1 ≤ E_new2 ? (p_new1, E_new1) : (p_new2, E_new2)

    return p_new, E_new
end

function simplex_opt(
        n::Int,
        p::Int,
        y::Int;
        K::Int = 3,
        d₀::Float64 = 1.0,
        seed::Int = 411068089483816338,
        iters::Int = 1_000,
        rescale_factor::Float64 = 0.99,
        max_failures::Integer = 5,
    )

    @assert 0 ≤ d₀ ≤ √2

    d = d₀

    seed > 0 && Random.seed!(seed)

    filename = "run.n_$n.p_$p.y_$y.d_$d.df_$rescale_factor.txt"

    trainset, trainlabels = dataset(n, p)
    # n here is the input size, for a tree committee with hL_size = 3 we need 3*n parameters

    ## Create the initial y points
    ## the factors are such that the points all have norm 1 and
    ## distance d between them (in expectation)
    c0 = √((1 - d^2 / 2) / n) * randn(n)
    ps = c0 .+ (d / √(2n)) .* randn(n, y)

    ## Energies
    Es = [energy(ps[:,i], K, trainset, trainlabels) for i = 1:y]
    E_best, E_worst = extrema(Es)

    ## Pre-compute the sum of all points
    vsum = vec(sum(ps, dims=2))

    ## Barycenter
    c = vsum / y

    Ec = energy(c, K, trainset, trainlabels)
    @info "it = 0 d = $d Ec = $(Ec) Es = $(mean(Es)) ± $(std(Es)) [$(extrema(Es))]"
    norms = [norm(ps[:,i]) for i=1:y]
    println("norm of replicas: $(mean(norms)) ± $(std(norms))")
    dists = [norm(ps[:,i] - ps[:,j]) for i = 1:y for j = (i+1):y]
    println("dists between replicas: $(mean(dists)) ± $(std(dists))")


    it = 0
    failures = 0
    while all(Es .> 0) && Ec > 0
        it += 1
        E_worst = maximum(Es)
        ## Find a new point with lower energy
        failed = true
        for attempt = 1:iters
            i_sub = rand(1:y)
            E_sub = Es[i_sub]
            p_new, E_new = gen_candidate(ps, vsum, i_sub, d, trainset, trainlabels, K)
            if E_new < E_worst
                Es[i_sub] = E_new
                E_worst = maximum(Es)

                ps[:, i_sub] = p_new
                vsum = vec(sum(ps, dims=2))
                c = vsum / y
                Ec = energy(c, K, trainset, trainlabels)

                failed = false
                (E_new == 0 || Ec == 0) && break
            end
        end

        if failed
            failures += 1
        else
            failures = 0
        end

        scale = norm(c) / √(1 - d^2 / 2)
        ps ./= scale
        vsum ./= scale
        c ./= scale

        @assert Ec == energy(c, K, trainset, trainlabels)

        @info "it = $it [$failures] d = $d Ec = $(Ec) Es = $(mean(Es)) ± $(std(Es)) [$(extrema(Es))]"
        norms = [norm(ps[:,i]) for i=1:y]
        println("norm of replicas: $(mean(norms)) ± $(std(norms))")
        dists = [norm(ps[:,i] - ps[:,j]) for i = 1:y for j = (i+1):y]
        println("dists between replicas: $(mean(dists)) ± $(std(dists))")

        d *= rescale_factor

        failures < max_failures && continue

        # if failures ≥ max_failures
        #     @info "failed $failures times, give up"
        #     break
        # end
        #
        # if d < 1e-4
        #     @info "min dist reached, give up"
        #     break
        # end

        @info "failed $failures times, reshuffle"

        failures = 0

        d = 1.0

        c0 = c
        ps = c0 .+ (d / √(2n)) .* randn(n, y)

        norms = [norm(ps[:,i]) for i=1:y]
        println("norm of replicas: $(mean(norms)) ± $(std(norms))")
        dists = [norm(ps[:,i] - ps[:,j]) for i = 1:y for j = (i+1):y]
        println("dists of replicas: $(mean(dists)) ± $(std(dists))")

        Es = [energy(ps[:,i], K, trainset, trainlabels) for i = 1:y]
        E_best, E_worst = extrema(Es)

        vsum = vec(sum(ps, dims=2))
        c = vsum / y
        Ec = energy(c, K, trainset, trainlabels)

        # # open(filename, "a") do io
        # #     println(io, "it = $it d = $d Ec = $Ec Es = $Es")
        # # end
    end

    return ps, Ec, Es
end

end # module
