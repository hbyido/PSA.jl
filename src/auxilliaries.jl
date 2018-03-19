using LightGraphs
using PyCall
const networkx = PyNULL()
copy!(networkx, pyimport("networkx" ))


function time_dependent_components(network)
    return [field for field=fieldnames(network) if String(field)[end-1:end]=="_t"]
end

function set_snapshots!(network, snapshots)
    for field=time_dependent_components(network)
        for df_name=keys(getfield(network,field))
            if nrow(getfield(network,field)[df_name])>0
                getfield(network,field)[df_name] = getfield(network,field)[df_name][snapshots, :]
            end
        end
    end
    network.snapshots = network.snapshots[snapshots,:]
end




# auxilliary functions
idx(dataframe) = Dict(zip(dataframe[:name], Iterators.countfrom(1)))
rev_idx(dataframe) = Dict(zip(Iterators.countfrom(1), dataframe[:name]))
idx_by(dataframe, col, values) = select_by(dataframe, col, values)[:idx]

function select_by(dataframe, col, selector)
    if length(findin(dataframe[col], selector))==0
        return dataframe[repeat(Bool[false],outer=nrow(dataframe)) , :]
    else
        mdict = Dict(zip(dataframe[col], Iterators.countfrom(1)))
        ids = Array{Int,1}(0)
        for i in selector
            push!(ids, mdict[i])
        end
        dataframe[ids,:]
    end
end
select_names(a, b) = select_by(a, :name, b)


function append_idx_col!(dataframe)
    if typeof(dataframe)==Vector{DataFrames.DataFrame}
        for df in dataframe
            df[:idx] = 1:nrow(df)
        end
    else
        dataframe[:idx] = 1:nrow(dataframe)
    end
end

function get_switchable_as_dense(network, component, attribute, snapshots=0)
    snapshots==0 ? snapshots = network.snapshots : nothing
    T = nrow(snapshots)
    component_t = Symbol(component * "_t")
    component = Symbol(component)
    dense = DataFrame()
    if in(attribute, keys(getfield(network, component_t)))
        dense = getfield(network, component_t)[attribute]
    end
    cols = Symbol.(getfield(network, component)[:name])
    not_included = String.(setdiff(cols, names(dense)))
    if length(not_included)>0
        attribute = Symbol.(attribute)
        df = select_names(getfield(network, component), not_included)
        df = names!(DataFrame(repmat(transpose(Array(df[attribute])), T)),
                Symbol.(not_included))
        dense = [dense df]
    end
    return dense[cols]
end


function calculate_dependent_values!(network)
    function set_default(dataframe, col, default)
        !in(col, names(dataframe)) ? dataframe[col] = default : nothing
    end

    # generators
    defaults = [(:p_nom_extendable, false), (:p_nom_max, Inf),(:commitable, false),
                (:p_min_pu, 0), (:p_max_pu, 1), (:p_nom_min, 0),(:capital_cost, 0),
                (:min_up_time, 0), (:min_down_time, 0), (:initial_status, true),
                (:p_nom, NaN)]
    for (col, default) in defaults
        set_default(network.generators, col, default)
    end

    # lines
    network.lines[:v_nom]=select_names(network.buses, network.lines[:bus0])[:v_nom]
    defaults = [(:s_nom_extendable, false), (:s_nom_min, 0),(:s_nom_max, Inf),
                (:s_nom_min, 0), (:s_nom_max, Inf), (:capital_cost, 0), (:g, 0)]
    for (col, default) in defaults
        set_default(network.lines, col, default)
    end
    network.lines[:x_pu] = network.lines[:x]./(network.lines[:v_nom].^2)
    network.lines[:r_pu] = network.lines[:r]./(network.lines[:v_nom].^2)
    network.lines[:b_pu] = network.lines[:b].*network.lines[:v_nom].^2
    network.lines[:g_pu] = network.lines[:g].*network.lines[:v_nom].^2

    # links
    defaults = [(:p_nom_extendable, false), (:p_nom_max, Inf), (:p_min_pu, 0),
                (:p_max_pu, 1),(:p_nom_min, 0), (:p_nom_max, Inf), (:capital_cost, 0)]
    for (col, default) in defaults
        set_default(network.links, col, default)
    end

    # storage_units
    defaults = [(:p_nom_min, 0), (:p_nom_max, Inf), (:p_min_pu, -1),
                    (:p_max_pu, 1), (:marginal_cost, 0), (:efficiency_store, 1),
                    (:efficiency_dispatch, 1), (:inflow, 0)]
    for (col, default) in defaults
        set_default(network.storage_units, col, default)
    end

    # storages
    defaults = [(:e_nom_min, 0), (:e_nom_max, Inf), (:e_min_pu, -1),
                    (:e_max_pu, 1), (:marginal_cost, 0), (:efficiency_store, 1),
                    (:efficiency_dispatch, 1), (:inflow, 0)]
    for (col, default) in defaults
        set_default(network.storage_units, col, default)
    end

    # loads_t
    for df_name=keys(network.loads_t)
        if nrow(network.loads_t[df_name])>1
            for bus=[bus for bus in network.buses[:name] if 
                !in(Symbol(bus), names(network.loads_t[df_name]))]
                set_default(network.loads_t[df_name], bus, 0)
            end
        end
    end 
end

function to_graph(network) 
    busidx = idx(network.buses)
    g = DiGraph(length(busidx))
    for l in eachrow(network.lines)
        add_edge!(g, busidx[l[:bus0]], busidx[l[:bus1]] )
    end 
    for l in eachrow(network.links)
        add_edge!(g, busidx[l[:bus0]], busidx[l[:bus1]] )
    end 
    return g
end

# function to_graphx(network) 
#     busidx = idx(network.buses)
#     g = networkx[:Graph]()
#     g[:add_nodes_from](busidx)
#     g[:add_edges_from]([(busidx[l[:bus0]], busidx[l[:bus1]]) for l in eachrow(network.lines)])
#     return g
# end

function incidence_matrix(network)
    busidx = idx(network.buses)
    lines = network.lines
    K = zeros(nrow(network.buses),nrow(lines))
    for l in 1:size(K)[2]
        K[busidx[lines[l,:bus0]],l] = 1
        K[busidx[lines[l,:bus1]],l] = -1
    end
    return K
end

function laplace_matrix(network)
    K = incidence_matrix(network)
    return K*K'
end

function ptdf_matrix(network)
    K = incidence_matrix(network)
    H = K' * pinv(K*K')
    return H .- H[:,1]
end

function get_cycles(network) 
    busidx = idx(network.buses)
    g = networkx[:Graph]()
    g[:add_nodes_from](busidx)
    g[:add_edges_from]([(busidx[l[:bus0]], busidx[l[:bus1]]) for l in eachrow(network.lines)])
    networkx[:cycle_basis](g)
end
