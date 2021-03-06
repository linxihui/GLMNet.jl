module GLMNet
using DataFrames, Distributions, Compat

const libglmnet = joinpath(Pkg.dir("GLMNet"), "deps", "libglmnet.so")

import Base.getindex, Base.convert, Base.size, Base.show, DataFrames.predict
export glmnet!, glmnet, nactive, predict, glmnetcv, GLMNetPath, GLMNetCrossValidation, CompressedPredictorMatrix

immutable CompressedPredictorMatrix <: AbstractMatrix{Float64}
    ni::Int               # Number of predictors
    ca::Matrix{Float64}   # Predictor values
    ia::Vector{Int32}     # Predictor indices
    nin::Vector{Int32}    # Number of predictors in each solution
end

size(X::CompressedPredictorMatrix) = (X.ni, length(X.nin))

function getindex(X::CompressedPredictorMatrix, a::Int, b::Int)
    checkbounds(X, a, b)
    for i = 1:X.nin[b]
        if X.ia[i] == a
            return X.ca[i, b]
        end
    end
    return 0.0
end

function getindex(X::CompressedPredictorMatrix, a::AbstractVector{Int}, b::Int)
    checkbounds(X, a, b)
    out = zeros(length(a))
    for i = 1:X.nin[b]
        if first(a) <= X.ia[i] <= last(a)
            out[X.ia[i] - first(a) + 1] = X.ca[i, b]
        end
    end
    out
end

function getindex(X::CompressedPredictorMatrix, a::Union(Int, AbstractVector{Int}), b::AbstractVector{Int})
    checkbounds(X, a, b)
    out = zeros(length(a), length(b))
    for j = 1:length(b), i = 1:X.nin[b[j]]
        if first(a) <= X.ia[i] <= last(a)
            out[X.ia[i] - first(a) + 1, j] = X.ca[i, b[j]]
        end
    end
    out
end

# Get number of active predictors for a model in X
# nin can be > non-zero predictors under some circumstances...
function nactive(X::CompressedPredictorMatrix, b::Int)
    n = 0
    for i = 1:X.nin[b]
        n += X.ca[i, b] != 0
    end
    n
end
nactive(X::CompressedPredictorMatrix, b::AbstractVector{Int}=1:length(X.nin)) =
    [nactive(X, j) for j in b]

function convert{T<:Matrix{Float64}}(::Type{T}, X::CompressedPredictorMatrix)
    mat = zeros(X.ni, length(X.nin))
    for b = 1:size(mat, 2), i = 1:X.nin[b]
        mat[X.ia[i], b] = X.ca[i, b]
    end
    return mat
end

function show(io::IO, X::CompressedPredictorMatrix)
    println(io, "$(size(X, 1))x$(size(X, 2)) CompressedPredictorMatrix:")
    Base.showarray(io, convert(Matrix{Float64}, X); header=false)
end

immutable GLMNetPath{F<:Distribution}
    family::F
    a0::Vector{Float64}              # intercept values for each solution
    betas::CompressedPredictorMatrix # coefficient values for each solution
    null_dev::Float64                # Null deviance of the model
    dev_ratio::Vector{Float64}       # R^2 values for each solution
    lambda::Vector{Float64}          # lamda values corresponding to each solution
    npasses::Int                     # actual number of passes over the
                                     # data for all lamda values
end

# Compute the model response to predictors in X
# No inverse link is applied
makepredictmat(path::GLMNetPath, sz::Int, model::Int) = fill(path.a0[model], sz)
makepredictmat(path::GLMNetPath, sz::Int, model::UnitRange{Int}) = repmat(path.a0[model].', sz, 1)
function predict(path::GLMNetPath, X::AbstractMatrix,
                 model::Union(Int, AbstractVector{Int})=1:length(path.a0);
                 outtype = :link, offsets = zeros(size(X,1)))
    betas = path.betas
    ca = betas.ca
    ia = betas.ia
    nin = betas.nin
    
    y = makepredictmat(path, size(X, 1), model)
    for b = 1:length(model)
        m = model[b]
        for i = 1:nin[m]
            iia = ia[i]
            for d = 1:size(X, 1)
                y[d, b] += ca[i, m]*X[d, iia]
            end
        end
    end
    if any(offsets .!= 0)
        for b = 1:length(model)
            y[:, b] += offsets
        end
    end
    if isa(path, GLMNetPath{Binomial}) && outtype != :link
        y = 1. ./ (1. + exp(-y))
    elseif is(path, GLMNetPath{Poisson}) && outtype != :link
        y = exp(y)
    end
    y
end

abstract Loss
immutable MSE <: Loss
    y::Vector{Float64}
end
loss(l::MSE, i, mu) = abs2(l.y[i] - mu)

immutable LogisticDeviance <: Loss
    y::Matrix{Float64}
    fulldev::Vector{Float64}    # Deviance of model with parameter for each y
end
LogisticDeviance(y::Matrix{Float64}) =
    LogisticDeviance(y, [((y[i, 1] == 0.0 ? 0.0 : log(y[i, 1])) +
                          (y[i, 2] == 0.0 ? 0.0 : log(y[i, 2]))) for i = 1:size(y, 1)])

# These are hard-coded in the glmnet Fortran code
const PMIN = 1e-5
const PMAX = 1-1e-5
function loss(l::LogisticDeviance, i, mu)
    expmu = exp(mu)
    lf = expmu/(expmu+1)
    lf = lf < PMIN ? PMIN : lf > PMAX ? PMAX : lf
    2.0*(l.fulldev[i] - (l.y[i, 1]*log1p(-lf) + l.y[i, 2]*log(lf)))
end

immutable PoissonDeviance <: Loss
    y::Vector{Float64}
    fulldev::Vector{Float64}    # Deviance of model with parameter for each y
end
PoissonDeviance(y::Vector{Float64}) =
    PoissonDeviance(y, [y == 0.0 ? 0.0 : y*log(y) - y for y in y])
loss(l::PoissonDeviance, i, mu) = 2*(l.fulldev[i] - (l.y[i]*mu - exp(mu)))

devloss(::Normal, y) = MSE(y)
devloss(::Binomial, y) = LogisticDeviance(y)
devloss(::Poisson, y) = PoissonDeviance(y)

# Check the dimensions of X, y, and weights
function validate_x_y_weights(X, y, weights)
    size(X, 1) == size(y, 1) ||
        error(Base.LinAlg.DimensionMismatch("length of y must match rows in X"))
    length(weights) == size(y, 1) ||
        error(Base.LinAlg.DimensionMismatch("length of weights must match y"))
end

# Compute deviance for given model(s) with the predictors in X versus known
# responses in y with the given weight
function loss(path::GLMNetPath, X::AbstractMatrix{Float64},
              y::Union(AbstractVector{Float64}, AbstractMatrix{Float64}),
              weights::AbstractVector{Float64}=ones(size(y, 1)),
              lossfun::Loss=devloss(path.family, y),
              model::Union(Int, AbstractVector{Int})=1:length(path.a0);
              offsets = zeros(size(X, 1)))
    validate_x_y_weights(X, y, weights)
    mu = predict(path, X, model; offsets = offsets)
    devs = zeros(size(mu, 2))
    for j = 1:size(mu, 2), i = 1:size(mu, 1)
        devs[j] += loss(lossfun, i, mu[i, j])*weights[i]
    end
    devs/sum(weights)
end
loss(path::GLMNetPath, X::AbstractMatrix, y::Union(AbstractVector, AbstractMatrix),
     weights::AbstractVector=ones(size(y, 1)), va...; kw...) =
  loss(path, convert(Matrix{Float64}, X), convert(Array{Float64}, y),
       convert(Vector{Float64}, weights), va...; kw...)

modeltype(::Normal) = "Least Squares"
modeltype(::Binomial) = "Logistic"
modeltype(::Poisson) = "Poisson"

function show(io::IO, g::GLMNetPath)
    println(io, "$(modeltype(g.family)) GLMNet Solution Path ($(size(g.betas, 2)) solutions for $(size(g.betas, 1)) predictors in $(g.npasses) passes):")
    print(io, DataFrame(df=nactive(g.betas), pct_dev=g.dev_ratio, λ=g.lambda))
end

function check_jerr(jerr, maxit)
    if 0 < jerr < 7777
        error("glmnet: memory allocation error")
    elseif jerr == 7777
        error("glmnet: all used predictors have zero variance")
    elseif jerr == 1000
        error("glmnet: all predictors are unpenalized")
    elseif -10001 < jerr < 0
        warn("glmnet: convergence for $(-jerr)th lambda value not reached after $maxit iterations")
    elseif jerr < -10000
        warn("glmnet: number of non-zero coefficients along path exceeds $nx at $(maxit+10000)th lambda value")
    end
end

macro validate_and_init()
    esc(quote
        validate_x_y_weights(X, y, weights)
        length(penalty_factor) == size(X, 2) ||
            error(Base.LinAlg.DimensionMismatch("length of penalty_factor must match rows in X"))
        (size(constraints, 1) == 2 && size(constraints, 2) == size(X, 2)) ||
            error(Base.LinAlg.DimensionMismatch("contraints must be a 2 x n matrix"))
        0 <= lambda_min_ratio <= 1 || error("lambda_min_ratio must be in range [0.0, 1.0]")

        if !isempty(lambda)
            # user-specified lambda values
            nlambda == 100 || error("cannot specify both lambda and nlambda")
            lambda_min_ratio == (length(y) < size(X, 2) ? 1e-2 : 1e-4) ||
                error("cannot specify both lambda and lambda_min_ratio")
            nlambda = length(lambda)
            lambda_min_ratio = 2.0
        end

        lmu = Int32[0]
        a0 = zeros(Float64, nlambda)
        ca = Array(Float64, pmax, nlambda)
        ia = Array(Int32, pmax)
        nin = Array(Int32, nlambda)
        fdev = Array(Float64, nlambda)
        alm = Array(Float64, nlambda)
        nlp = Int32[0]
        jerr = Int32[0]
    end)
end

macro check_and_return()
    esc(quote
        check_jerr(jerr[1], maxit)

        lmu = lmu[1]
        # first lambda is infinity; changed to entry point
        if isempty(lambda) && length(alm) > 2
            alm[1] = exp(2*log(alm[2])-log(alm[3]))
        end
        X = CompressedPredictorMatrix(size(X, 2), ca[:, 1:lmu], ia, nin[1:lmu])
        GLMNetPath(family, a0[1:lmu], X, null_dev, fdev[1:lmu], alm[1:lmu], @compat Int(nlp[1]))
    end)
end

function glmnet!(X::Matrix{Float64}, y::Vector{Float64},
             family::Normal=Normal();
             weights::Vector{Float64}=ones(length(y)),
             naivealgorithm::Bool=(size(X, 2) >= 500), alpha::Real=1.0,
             penalty_factor::Vector{Float64}=ones(size(X, 2)),
             constraints::Array{Float64, 2}=[x for x in (-Inf, Inf), y in 1:size(X, 2)],
             dfmax::Int=size(X, 2), pmax::Int=min(dfmax*2+20, size(X, 2)), nlambda::Int=100,
             lambda_min_ratio::Real=(length(y) < size(X, 2) ? 1e-2 : 1e-4),
             lambda::Vector{Float64}=Float64[], tol::Real=1e-7, standardize::Bool=true,
             intercept::Bool=true, maxit::Int=1000000)
    @validate_and_init

    ccall((:elnet_, libglmnet), Void,
          (Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
           Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
           Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
           Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}),
          &(naivealgorithm ? 2 : 1), &alpha, &size(X, 1), &size(X, 2), X, y, weights, &0,
          penalty_factor, constraints, &dfmax, &pmax, &nlambda, &lambda_min_ratio, lambda, &tol,
          &standardize, &intercept, &maxit, lmu, a0, ca, ia, nin, fdev, alm, nlp, jerr)

    null_dev = 0.0
    mu = mean(y)
    for i = 1:length(y)
        null_dev += abs2(null_dev-mu)
    end

    @check_and_return
end

function glmnet!(X::Matrix{Float64}, y::Matrix{Float64},
             family::Binomial;
             offsets::Union(Vector{Float64}, Nothing)=nothing,
             weights::Vector{Float64}=ones(size(y, 1)),
             alpha::Real=1.0,
             penalty_factor::Vector{Float64}=ones(size(X, 2)),
             constraints::Array{Float64, 2}=[x for x in (-Inf, Inf), y in 1:size(X, 2)],
             dfmax::Int=size(X, 2), pmax::Int=min(dfmax*2+20, size(X, 2)), nlambda::Int=100,
             lambda_min_ratio::Real=(length(y) < size(X, 2) ? 1e-2 : 1e-4),
             lambda::Vector{Float64}=Float64[], tol::Real=1e-7, standardize::Bool=true,
             intercept::Bool=true, maxit::Int=1000000, algorithm::Symbol=:newtonraphson)
    @validate_and_init
    size(y, 2) == 2 || error("glmnet for logistic models requires a two-column matrix with "*
                             "counts of negative responses in the first column and positive "*
                             "responses in the second")
    kopt = algorithm == :newtonraphson ? 0 :
           algorithm == :modifiednewtonraphson ? 1 :
           algorithm == :nzsame ? 2 : error("unknown algorithm ")
    offsets::Vector{Float64} = isa(offsets, Nothing) ? zeros(size(y, 1)) : copy(offsets)
    length(offsets) == size(y, 1) || error("length of offsets must match length of y")

    null_dev = Array(Float64, 1)

    # The Fortran code expects positive responses in first column, but
    # this convention is evidently unacceptable to the authors of the R
    # code, and, apparently, to us
    for i = 1:size(y, 1)
        a = y[i, 1]
        b = y[i, 2]
        y[i, 1] = b*weights[i]
        y[i, 2] = a*weights[i]
    end

    ccall((:lognet_, libglmnet), Void,
          (Ptr{Float64}, Ptr{Int32}, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64},  Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Int32}, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}),
          &alpha, &size(X, 1), &size(X, 2), &1, X, y, copy(offsets), &0, penalty_factor,
          constraints, &dfmax, &pmax, &nlambda, &lambda_min_ratio, lambda, &tol, &standardize,
          &intercept, &maxit, &kopt, lmu, a0, ca, ia, nin, null_dev, fdev, alm, nlp, jerr)

    null_dev = null_dev[1]
    @check_and_return
end

function glmnet!(X::Matrix{Float64}, y::Vector{Float64},
             family::Poisson;
             offsets::Union(Vector{Float64}, Nothing)=nothing,
             weights::Vector{Float64}=ones(length(y)),
             alpha::Real=1.0,
             penalty_factor::Vector{Float64}=ones(size(X, 2)),
             constraints::Array{Float64, 2}=[x for x in (-Inf, Inf), y in 1:size(X, 2)],
             dfmax::Int=size(X, 2), pmax::Int=min(dfmax*2+20, size(X, 2)), nlambda::Int=100,
             lambda_min_ratio::Real=(length(y) < size(X, 2) ? 1e-2 : 1e-4),
             lambda::Vector{Float64}=Float64[], tol::Real=1e-7, standardize::Bool=true,
             intercept::Bool=true, maxit::Int=1000000)
    @validate_and_init
    null_dev = Array(Float64, 1)

    offsets::Vector{Float64} = isa(offsets, Nothing) ? zeros(length(y)) : copy(offsets)
    length(offsets) == length(y) || error("length of offsets must match length of y")

    ccall((:fishnet_, libglmnet), Void,
          (Ptr{Float64}, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32},
           Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}),
          &alpha, &size(X, 1), &size(X, 2), X, y, offsets, weights, &0, penalty_factor,
          constraints, &dfmax, &pmax, &nlambda, &lambda_min_ratio, lambda, &tol, &standardize,
          &intercept, &maxit, lmu, a0, ca, ia, nin, null_dev, fdev, alm, nlp, jerr)

    null_dev = null_dev[1]
    @check_and_return
end

glmnet(X::Matrix{Float64}, y::Vector{Float64}, family::Distribution=Normal(); kw...) =
    glmnet!(copy(X), copy(y), family; kw...)
glmnet(X::AbstractMatrix, y::AbstractVector, family::Distribution=Normal(); kw...) =
    glmnet(convert(Matrix{Float64}, X), convert(Vector{Float64}, y), family; kw...)
glmnet(X::Matrix{Float64}, y::Matrix{Float64}, family::Binomial; kw...) =
    glmnet!(copy(X), copy(y), family; kw...)
glmnet(X::Matrix, y::Matrix, family::Binomial; kw...) =
    glmnet(convert(Matrix{Float64}, X), convert(Matrix{Float64}, y), family; kw...)

immutable GLMNetCrossValidation
    path::Any
    nfolds::Int
    lambda::Vector{Float64}
    meanloss::Vector{Float64}
    stdloss::Vector{Float64}
end

function show(io::IO, cv::GLMNetCrossValidation)
    g = cv.path
    println(io, "$(modeltype(g.family)) GLMNet Cross Validation")
    println(io, "$(length(cv.lambda)) models for $(size(g.betas, 1)) predictors in $(cv.nfolds) folds")
    x, i = findmin(cv.meanloss)
    @printf io "Best λ %.3f (mean loss %.3f, std %.3f)" cv.lambda[i] x cv.stdloss[i]
    print(io, )
end

function glmnetcv(X::AbstractMatrix, y::Union(AbstractVector, AbstractMatrix),
                  family::Distribution=Normal(); weights::Vector{Float64}=ones(size(X,1)),
                  offsets::Union(AbstractVector, AbstractMatrix, Nothing)=nothing,
                  nfolds::Int=min(10, div(size(y, 1), 3)),
                  folds::Vector{Int}=begin
                      n, r = divrem(size(y, 1), nfolds)
                      shuffle!([repmat(1:nfolds, n); 1:r])
                  end, parallel::Bool=false, kw...)
    # Fit full model once to determine parameters
    X = convert(Matrix{Float64}, X)
    y = convert(Array{Float64}, y)
    offsets = (offsets != nothing)? offsets : isa(family, Multinomial)?  y*0.0 : zeros(size(X, 1))

    if isa(family, Normal)
        path = glmnet(X, y, family; weights = weights, kw...)
    else
        path = glmnet(X, y, family; weights = weights, offsets = offsets, kw...)
    end

    # In case user defined folds
    nfolds = maximum(folds)

    # We shouldn't pass on nlambda and lambda_min_ratio if the user
    # specified these, since that would make us throw errors, and this
    # is entirely determined by the lambda values we will pass
    filter!(kw) do akw
        kwname = akw[1]
        kwname != :nlambda && kwname != :lambda_min_ratio && kwname != :lambda
    end

    # Do model fits and compute loss for each
    fits = (parallel ? pmap : map)(1:nfolds) do i
        f = folds .== i
        holdoutidx = find(f)
        modelidx = find(!f)
        if isa(family, Normal)
            g = glmnet!(X[modelidx, :], isa(y, AbstractVector) ? y[modelidx] : y[modelidx, :], family;
                        weights=weights[modelidx], lambda=path.lambda, kw...)
        else
            g = glmnet!(X[modelidx, :], isa(y, AbstractVector) ? y[modelidx] : y[modelidx, :], family;
                        weights=weights[modelidx], offsets = isa(offsets, AbstractVector) ? offsets[modelidx] : offsets[modelidx, :],
                        lambda=path.lambda, kw...)
        end
        loss(g, X[holdoutidx, :], isa(y, AbstractVector) ? y[holdoutidx] : y[holdoutidx, :], weights[holdoutidx]; 
            offsets = isa(offsets, AbstractVector) ? offsets[holdoutidx] : offsets[holdoutidx, :])
    end

    # each fold may result in a smaller number of lambdas
    lambda = path.lambda[1:minimum(map(length, fits))]
    fits = map(z->z[1:length(lambda)], fits)

    fitloss = hcat(fits...)::Matrix{Float64}

    ninfold = zeros(Int, nfolds)
    for f in folds
        ninfold[f] += 1
    end

    # Mean weighted by fold size
    meanloss = zeros(size(fitloss, 1))
    for j = 1:size(fitloss, 2)
        wfold = ninfold[j]/length(folds)
        for i = 1:size(fitloss, 1)
            meanloss[i] += fitloss[i, j]*wfold
        end
    end

    # Standard deviation weighted by fold size
    stdloss = zeros(size(fitloss, 1))
    for j = 1:size(fitloss, 2)
        wfold = ninfold[j]
        for i = 1:size(fitloss, 1)
            stdloss[i] += abs2(fitloss[i, j] - meanloss[i])*wfold
        end
    end
    for i = 1:size(fitloss, 1)
        stdloss[i] = sqrt(stdloss[i]/length(folds)/(nfolds - 1))
    end

    GLMNetCrossValidation(path, nfolds, path.lambda, meanloss, stdloss)
end

include("Multinomial.jl")
include("CoxNet.jl")
include("plot.jl")

end # module
