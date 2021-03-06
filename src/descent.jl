# temporary draft implementation to eventually replace nn_descent.jl

"""
    nndescent(GraphT::Type{ApproximateKNNGraph}, data, n_neighbors, metric; kwargs...)

Find the approximate neighbors of each point in `data` by  iteratively
refining a KNN graph of type `GraphT`. Returns the final KNN graph.

# Keyword Arguments
- `max_iters = 10`: Limits the number of iterations to refine candidate
nearest neighbors. Higher values trade off speed for accuracy. Note that graph
construction may terminate early if little progress is being made.
- `sample_rate = 1`: The sample rate for calculating *local joins*
around each point. Lower values trade off accuracy for speed.
- `precision = 1e-3`: The threshold for early termination,
where precision is "roughly the fraction of true kNN allowed to be missed due to
early termination". Lower values take longer but return more accurate results.
"""
function nndescent(GraphT::Type{<:ApproximateKNNGraph},
                   data::AbstractVector,
                   n_neighbors::Integer,
                   metric::PreMetric;
                   max_iters = 10,
                   sample_rate = 1,
                   precision = 1e-3,
                  )

    validate_args(data, n_neighbors, metric, max_iters, sample_rate, precision)

    graph = GraphT(data, n_neighbors, metric)
    for i in 1:max_iters
        c = local_join!(graph; sample_rate=sample_rate)
        if c ≤ precision * n_neighbors * nv(graph)
            break
        end
    end
    return graph
end

"""
    nndescent(::Type{<:ApproximateKNNGraph}, data::AbstractMatrix, n_neighbors::Integer, metric::PreMetric; kwargs...)
"""
function nndescent(GraphT,
                   data::AbstractMatrix,
                   n_neighbors,
                   metric;
                   kwargs...
                  )
    return nndescent(GraphT, [col for col in eachcol(data)], n_neighbors, metric; kwargs...)
end

"""
    nndescent(data, n_neighbors, metric; kwargs...)

Do nndescent using `HeapKNNGraph` as the KNN Graph type.
"""
nndescent(data, n_neighbors, metric; kwargs...) = nndescent(HeapKNNGraph, data, n_neighbors, metric; kwargs...)

"""
    local_join!(graph; kwargs...)

Perform a local join on each vertex `v`'s neighborhood `N[v]` in `graph`. Given vertex `v`
and its neighbors `N[v]`, compute the similarity `graph.metric(p, q)` for each pair `p, q ∈ N[v]`
and update `N[q]` and `N[p]`.

This mutates `graph` in-place and returns a nonnegative integer indicating how many neighbor
updates took place during the local join.
"""
function local_join! end

function local_join!(graph::HeapKNNGraph; sample_rate = 1)
    # find in and out neighbors - old neighbors have already participated in a previous local join
    data = graph.data
    metric = graph.metric
    old_neighbors, new_neighbors = get_neighbors!(graph, sample_rate)
    c = 0
    # compute local join
    for v in vertices(graph)
        for p in new_neighbors[v]
            for q in (q_ for q_ in new_neighbors[v] if p < q_)
                # both new
                dist = evaluate(metric, data[p], data[q])
                c += add_edge!(graph, edgetype(graph)(p, q, dist))
                if !(metric isa SemiMetric) # not symmetric
                    dist = evaluate(metric, data[q], data[p])
                end
                c += add_edge!(graph, edgetype(graph)(q, p, dist))

            end
            for q in (q_ for q_ in old_neighbors[v] if p != q_)
                # one new, one old
                dist = evaluate(metric, data[p], data[q])
                c += add_edge!(graph, edgetype(graph)(p, q, dist))
                if !(metric isa SemiMetric) # not symmetric
                    dist = evaluate(metric, data[q], data[p])
                end
                c += add_edge!(graph, edgetype(graph)(q, p, dist))
            end
        end
    end

    return c
end


function local_join!(graph::LockHeapKNNGraph; sample_rate = 1)
    data = graph.data
    metric = graph.metric
    old_neighbors, new_neighbors = get_neighbors!(graph, sample_rate)
    count = Threads.Atomic{Int}(0)
    # compute local join
    Threads.@threads for v in vertices(graph)
        for p in new_neighbors[v]
            for q in (q_ for q_ in new_neighbors[v] if p < q_)
                # both new
                dist = evaluate(metric, data[p], data[q])
                res = add_edge!(graph, edgetype(graph)(p, q, dist))
                Threads.atomic_add!(count, Int(res))
                if !(metric isa SemiMetric) # not symmetric
                    dist = evaluate(metric, data[q], data[p])
                end
                res = add_edge!(graph, edgetype(graph)(q, p, dist))
                Threads.atomic_add!(count, Int(res))
            end
            for q in (q_ for q_ in old_neighbors[v] if p != q_)
                # one new, one old
                dist = evaluate(metric, data[p], data[q])
                res = add_edge!(graph, edgetype(graph)(p, q, dist))
                Threads.atomic_add!(count, Int(res))
                if !(metric isa SemiMetric) # not symmetric
                    dist = evaluate(metric, data[q], data[p])
                end
                res = add_edge!(graph, edgetype(graph)(q, p, dist))
                Threads.atomic_add!(count, Int(res))
            end
        end
    end
    return count[]
end

"""
Get the neighbors of each point in a KNN graph `graph` as sets of integer ids.

For the NNDescent algorithm, these are separated into the old and new neighbors.
"""
function get_neighbors!(graph::ApproximateKNNGraph{V}, sample_rate=1) where V
    old_neighbors = [V[] for _ in 1:nv(graph)]
    new_neighbors = [V[] for _ in 1:nv(graph)]
    for ind in edge_indices(graph)
        @inbounds e = node_edge(graph, ind[1], ind[2])
        if flag(e) # isnew(e) => new edges haven't participated in local join
            if rand() ≤ sample_rate
                # mark sampled new forward neighbors as old
                @inbounds e = update_flag!(graph, ind[1], ind[2], false)
                push!(new_neighbors[src(e)], dst(e))
                push!(new_neighbors[dst(e)], src(e))
            end
        else # old neighbors
            # always include old forward
            push!(old_neighbors[src(e)], dst(e))
            # sample old reverse neighbors
            if rand() ≤ sample_rate
                push!(old_neighbors[dst(e)], src(e))
            end
        end
    end
    return (unique!).((sort!).(old_neighbors)), (unique!).((sort!).(new_neighbors))
end
