using DynamicExpressions:
    AbstractExpression,
    AbstractExpressionNode,
    OperatorEnum,
    constructorof,
    DynamicExpressions as DE

"""
    D(ex::AbstractExpression, feature::Integer)

Compute the derivative of `ex` with respect to the `feature`-th variable.
Returns a new expression with an expanded set of operators.
"""
function D(ex::AbstractExpression, feature::Integer)
    metadata = DE.get_metadata(ex)
    raw_metadata = getfield(metadata, :_data)  # TODO: Upstream this so we can load this
    operators = DE.get_operators(ex)
    mult_idx = findfirst(==(*), operators.binops)::Integer
    plus_idx = findfirst(==(+), operators.binops)::Integer
    nbin = length(operators.binops)
    nuna = length(operators.unaops)
    tree = DE.get_contents(ex)
    operators_with_derivatives = _make_derivative_operators(operators)
    evaluates_to_constant = map(
        op -> if op == _zero
            Zero
        elseif op == _one
            One
        elseif op == _n_one
            NegOne
        else
            NonConstant
        end, operators_with_derivatives.binops
    )
    ctx = SymbolicDerivativeContext(;
        feature, plus_idx, mult_idx, nbin, nuna, evaluates_to_constant
    )
    d_tree = _symbolic_derivative(tree, ctx)
    return DE.with_metadata(
        DE.with_contents(ex, d_tree); raw_metadata..., operators=operators_with_derivatives
    )
end

# Used to declare if an operator will always evaluate to a constant.
Base.@enum EvaluatesToConstant::UInt8 Zero One NegOne NonConstant

# Holds metadata about the derivative computation.
Base.@kwdef struct SymbolicDerivativeContext{TUP}
    feature::Int
    plus_idx::Int
    mult_idx::Int
    nbin::Int
    nuna::Int
    evaluates_to_constant::TUP
end

function _symbolic_derivative(
    tree::N, ctx::SymbolicDerivativeContext
) where {T,N<:AbstractExpressionNode{T}}
    # NOTE: We cannot mutate the tree here! Since we use it twice.

    # Quick test to see if we have any dependence on the feature, so
    # we can return 0 for the branch
    any_dependence = any(tree) do node
        node.degree == 0 && !node.constant && node.feature == ctx.feature
    end

    if !any_dependence
        return constructorof(N)(; val=zero(T))
    elseif tree.degree == 0 # && any_dependence
        return constructorof(N)(; val=one(T))
    elseif tree.degree == 1
        # f(g(x)) => f'(g(x)) * g'(x)
        f_prime_op = tree.op + ctx.nuna

        ### We do some simplification based on zero/one derivatives ###
        g_prime = _symbolic_derivative(tree.l, ctx)
        if g_prime.degree == 0 && g_prime.constant && iszero(g_prime.val)
            # f' * 0 => 0
            return g_prime
        else
            f_prime = constructorof(N)(; op=f_prime_op, l=tree.l)

            if g_prime.degree == 0 && g_prime.constant && isone(g_prime.val)
                # f' * 1 => f'
                return f_prime
            else
                return constructorof(N)(; op=ctx.mult_idx, l=f_prime, r=g_prime)
            end
        end
    else  # tree.degree == 2
        # f(g(x), h(x)) => f^(1,0)(g(x), h(x)) * g'(x) + f^(0,1)(g(x), h(x)) * h'(x)
        f_prime_left_op = tree.op + ctx.nbin
        f_prime_right_op = tree.op + 2 * ctx.nbin
        f_prime_left_evaluates_to = ctx.evaluates_to_constant[f_prime_left_op]
        f_prime_right_evaluates_to = ctx.evaluates_to_constant[f_prime_right_op]

        ### We do some simplification based on zero/one derivatives ###
        first_term = if f_prime_left_evaluates_to == Zero
            # 0 * g' => 0
            constructorof(N)(; val=zero(T))
        else
            g_prime = _symbolic_derivative(tree.l, ctx)

            if f_prime_left_evaluates_to == One
                # 1 * g' => g'
                g_prime
            elseif g_prime.degree == 0 && g_prime.constant && iszero(g_prime.val)
                # f' * 0 => 0
                g_prime
            else
                f_prime_left = if f_prime_left_evaluates_to == NegOne
                    constructorof(N)(; val=-one(T))
                else
                    constructorof(N)(; op=f_prime_left_op, l=tree.l, r=tree.r)
                end

                if g_prime.degree == 0 && g_prime.constant && isone(g_prime.val)
                    # f' * 1 => f'
                    f_prime_left
                else
                    # f' * g'
                    constructorof(N)(; op=ctx.mult_idx, l=f_prime_left, r=g_prime)
                end
            end
        end

        second_term = if f_prime_right_evaluates_to == Zero
            # Simplify and just give zero
            constructorof(N)(; val=zero(T))
        else
            h_prime = _symbolic_derivative(tree.r, ctx)
            if f_prime_right_evaluates_to == One
                h_prime
            elseif h_prime.degree == 0 && h_prime.constant && iszero(h_prime.val)
                h_prime
            else
                f_prime_right = if f_prime_right_evaluates_to == NegOne
                    constructorof(N)(; val=-one(T))
                else
                    constructorof(N)(; op=f_prime_right_op, l=tree.l, r=tree.r)
                end
                if h_prime.degree == 0 && h_prime.constant && isone(h_prime.val)
                    f_prime_right
                else
                    constructorof(N)(; op=ctx.mult_idx, l=f_prime_right, r=h_prime)
                end
            end
        end

        # Simplify if either term is zero
        if first_term.degree == 0 && first_term.constant && iszero(first_term.val)
            return second_term
        elseif second_term.degree == 0 && second_term.constant && iszero(second_term.val)
            return first_term
        else
            return constructorof(N)(; op=ctx.plus_idx, l=first_term, r=second_term)
        end
    end
end

function _make_derivative_operators(operators::OperatorEnum)
    unaops = operators.unaops
    binops = operators.binops
    new_unaops = ntuple(
        i -> if i <= length(unaops)
            unaops[i]
        else
            operator_derivative(unaops[i - length(unaops)], Val(1), Val(1))
        end,
        Val(2 * length(unaops)),
    )
    new_binops = ntuple(
        i -> if i <= length(binops)
            binops[i]
        elseif i <= 2 * length(binops)
            operator_derivative(binops[i - length(binops)], Val(2), Val(1))
        else
            operator_derivative(binops[i - 2 * length(binops)], Val(2), Val(2))
        end,
        Val(3 * length(binops)),
    )
    return OperatorEnum(new_binops, new_unaops)
end