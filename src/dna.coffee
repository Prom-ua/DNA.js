DNA_EXTEND = 'extend'
DNA_SUBSCRIBE = 'subscribe'
DNA_ID_PREFIX = 'Z'

NAN =       'NaN'
NULL =      'null'
KEYWORD =   'keyword'
STRING =    'string'
INTEGER =   'integer'
FLOAT =     'float'
VECTOR =    'vector'
HASHMAP =   'hashmap'
BQ =        'bq'
RE =        're'

FUNCTION =  'fn'
PARTIAL_FN = 'partial'
NESTED_EXPR = 'nested'
QUOTED_NESTED_EXPR = 'quoted-nested'

DNA_PRIMITIVES = [NAN, NULL, KEYWORD, STRING, INTEGER, FLOAT, RE, BQ]
DNA_DATATYPES = [NAN, NULL, KEYWORD, STRING, INTEGER, FLOAT, VECTOR, HASHMAP, RE, BQ]
THIS = 'this'
BUILTIN = '*builtin*'

Math = require '../utils/Math.uuid'

{partial, is_array, is_object, bool, make_lambda,
 complement, compose3, distinct, repeat} = require 'libprotein'

{observe_dom_added} = require 'dom-mutation-observer'

parse_genome = (require 'genome-parser').parse

{
    register_protocol_impl
    dispatch_impl
    get_protocol
    is_async
    get_arity
} = require 'libprotocol'

{
    cont_t, cont_m,
    maybe_t, maybe_m,
    logger_t, logger_m,
    domonad, is_null,
    lift_sync, lift_async
} = require 'libmonad'

{info, warn, error, debug, nullog} = dispatch_impl 'ILogger', 'DNA'
{get_state, swap_state, watch_state} = require 'libstate'

MY_STATE = 'dna'
watch_my_state = (old_state, new_state) -> #debug "state changed", old_state, new_state

lazy_init_state = (state) ->
    # TODO types?
    state or= {}
    state.CELLS or= {}

    watch_state MY_STATE, watch_my_state

    state

process_ast_vector = (vector, cell, ctx, cont) ->
    # FIXME paralellize with arrows
    res = []

    if vector.length is 0
        cont res

    else
        count = vector.length

        local_cont = (idx) ->
            (r) ->
                res[idx] = r
                count--

                if count is 0
                    cont res

        vector.map (ast_node, idx) ->
            h = process_ast_handler_node cell, ctx, ast_node
            c = (local_cont idx)

            # vector currently passes no arguments to its member
            if h.meta.async
                h ((repeat undefined, h.meta.arity-1).concat [c])...
            else
                c (h (repeat undefined, h.meta.arity)...)

default_handlers_cont = (args...) ->
    #debug "DNA monadic sequence finished with results:", args

is_value = (type) -> type in DNA_DATATYPES

is_function = (type) -> type in [FUNCTION, PARTIAL_FN]

is_just_function = (type) -> type is FUNCTION

is_partial_function = (type) -> type is PARTIAL_FN

is_nested_expr = (type) -> type is NESTED_EXPR

lift = (h) ->
    if h.meta.async
        lift_async h.meta.arity, h
    else
        lift_sync h.meta.arity, h

get_method_ns = (name, cell) ->
    method_invariants = cell.receptors[name]

    if method_invariants?.length > 0
        method_invariants[0].ns

    else
        error "No such method: #{name} in the cell:", cell
        throw "Method missing in cell"

dispatch_handler = (ns, name, cell) ->
    method_invariants = cell.receptors[name]

    if method_invariants
        if ns
            method_from_given_ns = (method_invariants.filter (m) -> m.ns is ns)[0]
            if method_from_given_ns
                method_from_given_ns.impl

            else
               error "Method not found: #{ns}/#{name} in cell", cell
               throw "Method not found: #{ns}/#{name} in cell id=`#{cell.id}`"

        else
            if method_invariants.length is 1
                method_invariants[0].impl

            else
                error "More then one method with name `#{name}` found in cell and namespace not set", cell
                throw "More then one method with name `#{name}` found in cell id=`#{cell.id}` and namespace not set"
                
    else
        error "Method with name `#{name}` not found in cell", {ns, name, cell}
        throw "Method with name `#{name}` not found in cell id=`#{cell.id}`"

save_cell = (cell) ->
    swap_state MY_STATE, (old_state) ->
        new_state = lazy_init_state old_state
        new_state.CELLS[cell.id] = cell
        new_state

get_cell = (id) ->
    (lazy_init_state (get_state MY_STATE)).CELLS[id]

find_cell = (scope_id, this_cell, ctx) ->
    if (scope_id is THIS or not scope_id) and this_cell
        this_cell
    else if cell = get_cell scope_id
        cell
    else if cell = create_cell_by_id scope_id, ctx, this_cell.synthesis_id
        cell
    else
        null

create_cell_by_id = (id, ctx, synthesis_id) ->
    if node = ctx.dom_parser.get_by_id id
        create_cell ctx, synthesis_id, node
    else
        null

fun_with_meta = (fn, meta) ->
    fn.meta = meta
    fn

get_primitive_value_handler = (type, value) ->
    switch type
        when NAN
            fun_with_meta (-> NaN), {arity: 0, async: false, protocol: BUILTIN, name: "NaN"}
        when NULL
            fun_with_meta (-> null), {arity: 0, async: false, protocol: BUILTIN, name: "null"}
        when KEYWORD
            fun_with_meta (-> value), {arity: 0, async: false, protocol: BUILTIN, name: ":Keyword #{value}"}
        when STRING
            fun_with_meta (-> value), {arity: 0, async: false, ns: BUILTIN, name: "String '#{value}'"}
        when INTEGER
            fun_with_meta (-> value), {arity: 0, async: false, ns: BUILTIN, name: "Integer '#{value}'"}
        when FLOAT
            fun_with_meta (-> value), {arity: 0, async: false, ns: BUILTIN, name: "Float '#{value}'"}
        when BQ
            fun_with_meta (-> make_lambda value), {arity: 0, async: false, ns: BUILTIN, name: "`Lambda '#{value}'"}
        when RE
            fun_with_meta (-> ((a) -> value.test a)), {arity: 0, async: false, ns: BUILTIN, name: "/Regexp/ '#{value}'"} 
        else
            throw "Unknown primitive type: #{type}/#{value}"

get_value_handler = (type, value, cell, ctx) ->
    switch type
        when NAN, NULL, KEYWORD, STRING, INTEGER, FLOAT, BQ, RE
            get_primitive_value_handler type, value
        when VECTOR
            fun_with_meta(
                (cont) ->
                    process_ast_vector value, cell, ctx, (res) ->
                        cont res
                {async: true, arity: 1, protocol: BUILTIN, name: "Vector"}
            )
        when HASHMAP
            fun_with_meta(
                (key) -> if key then value[key] else value
                {arity: 1, async: false, protocol: BUILTIN, name: "Hashmap"}
            )
        else
            throw "Unknown type: #{type}"

make_nested_expr = (ctx, current_cell, handler) ->
    # will build strictly on initialization
    # f = make_monadized_handler ctx, current_cell, cont, handler
    fun_with_meta(
        (arg, cont) ->
            # will build lazyly on invocation
            f = make_monadized_handler ctx, current_cell, cont, handler
            f arg

        {async: true, arity: 2, protocol: BUILTIN, name: NESTED_EXPR}
    )

process_ast_handler_node = (current_cell, ctx, handler) ->
    _get_cell = (id) ->
        cell = find_cell id, current_cell, ctx

        unless cell
            error "Unknown cell referenced in handler", id, handler
            throw "Unknown cell referenced in handler"

        cell

    switch handler.type
        when FUNCTION
            dispatch_handler handler.ns, handler.name, (_get_cell (handler.scope or THIS))

        when PARTIAL_FN
            USE_LAZY_PARTIAL_ARGS = true

            h = (dispatch_handler handler.fn.ns,
                                  handler.fn.name,
                                  (_get_cell (handler.fn.scope or THIS)))

            if USE_LAZY_PARTIAL_ARGS
                ## lazy args
                {vargs, arity} = h.meta

                fun_with_meta(
                    (args...) ->
                        # TODO vargs support
                        accepted_args = args[0...arity]

                        process_ast_vector handler.args, current_cell, ctx, (calculated_args) ->
                            if h.meta.async
                                h (calculated_args.concat accepted_args)...
                            else
                                [raw_accepted_args..., cont] = accepted_args
                                cont (h (calculated_args.concat raw_accepted_args)...)

                    arity: arity
                    async: true
                    name: "partial application of #{h.meta.name}"
                    protocol: h.meta.protocol
                )

            else
                ## strict args, only sync
                (partial h, (handler.args.map ({type, value}) ->
                    unless type in DNA_PRIMITIVES
                        throw "Only primitive datatypes accepted as partial args"
                    (get_primitive_value_handler type, value)())...)

        when NESTED_EXPR
            make_nested_expr ctx, current_cell, handler.value

        when QUOTED_NESTED_EXPR
            throw "QUOTED_NESTED_EXPR is not implemented yet"

        when NAN, NULL, KEYWORD, STRING, INTEGER, FLOAT, VECTOR, HASHMAP, RE, BQ
            (get_value_handler handler.type,
                               handler.value,
                               (_get_cell (handler.scope or THIS)),
                               ctx)

        else
            error "Unknown expression type: #{handler.type}", handler
            throw "Unknown expression type: #{handler.type}"

process_meta = (cell, h) ->
    # TODO
    h

make_monadized_handler = (ctx, cell, cont, handlr) ->
    ast_parser = partial process_ast_handler_node, cell, ctx
    do_meta = partial process_meta, cell
    lifted_handlers_chain = handlr.seq.map (compose3 lift, do_meta, ast_parser)
    wrapper_monad = cont_t (logger_t (maybe_m {is_error: is_null}), nullog)

    fun_with_meta(
        (init_val) ->
            #debug "Starting DNA monadic sequence with arguments:", init_val
            (domonad wrapper_monad, lifted_handlers_chain, init_val) cont

        {async: true, arity: 1, name: 'monadized-handler'}
    )

bind_handlers_to_event = (ctx, cell, handlers, event_node) ->
    {type, args, name, ns, scope} = if event_node.type is 'partial-event'
        type:   'partial-event'
        args:   partial process_ast_vector, event_node.args, cell, ctx
        # simple solution to unboxing event partial args
        #args:   (event_node.args.map (partial process_ast_handler_node, cell, ctx)).map (a) -> a()
        name:   event_node.event.name
        ns:     event_node.event.ns
        scope:  event_node.event.scope
    else
        type:   'event'
        args:   []
        name:   event_node.name
        ns:     event_node.ns
        scope:  event_node.scope

    event_binder = (dispatch_handler ns,
                                     name,
                                     (find_cell (scope or THIS),
                                                cell,
                                                ctx))
    # TBD delegate this later
    handlers.map (handlr) ->
        if event_node.type is 'partial-event'
            # full-featured solution to unboxing event partial args
            args (processed_args) ->
                event_binder (processed_args.concat [handlr])...
        else
            event_binder (args.concat [handlr])...

make_dynamic_handler = (ctx, cell, cont, handlr) ->
    (args...) ->
        fresh_cell = find_cell cell.id, cell, ctx
        h = make_monadized_handler ctx, fresh_cell, cont, handlr
        h args...

process_subscribe = (cell) ->
    return if cell.subscriptions_processed

    cell.subscriptions_processed = true

    genome_string = cell.ctx.dom_parser.getData DNA_SUBSCRIBE, cell.node
    if (bool genome_string)
        genes = parse_genome genome_string
        # debug "DNA AST for", cell, ":", genes

        genes.map (gene) ->
            gene.events.map (partial bind_handlers_to_event,
                                     cell.ctx,
                                     cell,
                                     (gene.handlers.map (partial make_dynamic_handler,
                                                                 cell.ctx,
                                                                 cell,
                                                                 default_handlers_cont)))

synthesize_cell = (node, ctx, synthesis_id) ->
    unless node.id
        # id must start with a word char (or the grammar has to be updated)
        node.id = (ctx.dom_parser.get_id node) or DNA_ID_PREFIX + Math.uuid()

    proto_cell =
        id: node.id
        node: node
        receptors: {}
        impls: {}
        ctx: ctx
        synthesis_id: synthesis_id

    # Protocols must be unique. This must be validated at the registration step.

    extended_protocols = if extended_protocols = ctx.dom_parser.getData DNA_EXTEND, node
        (extended_protocols.split ' ').filter (i) -> !!i
    else
        []

    all_the_protocols = distinct (extended_protocols.concat ctx.default_protocols)

    all_the_protocols.map (protocol) ->
        p = get_protocol protocol
        proto_cell.impls[protocol] = dispatch_impl protocol, node

        unless is_object proto_cell.impls[protocol]
            error "Bad protocol implementation for DNA: #{protocol}", proto_cell.impls[protocol]
            throw "Bad protocol implementation for DNA: #{protocol} :: #{proto_cell.impls[protocol]}"

        if p and proto_cell.impls[protocol]
            p.map ([name, args]) ->
                m =
                    name: name
                    ns: protocol
                    impl: proto_cell.impls[protocol][name]

                if proto_cell.receptors[name]
                    proto_cell.receptors[name].push m
                else
                    proto_cell.receptors[name] = [m]

    proto_cell

create_cell = (ctx, synthesis_id, node) ->
    maybe_id = node.id
    sid = if maybe_id and (old_cell = get_cell maybe_id)
        debug "Reinstantiating cell with id #{maybe_id}"
        old_cell.synthesis_id + 1
    else
        synthesis_id

    cell = synthesize_cell node, ctx, sid
    save_cell cell
    cell

synthesize_node = (ctx) ->
    START_TIME = new Date
    synthesis_id = 0

    root_node = ctx.dom_parser.get_root_node()
    # debug 'Cells synthesis started for node', root_node

    active_nodes = ctx.dom_parser.get_by_attr "[data-#{DNA_EXTEND}], [data-#{DNA_SUBSCRIBE}]"
    creator = partial create_cell, ctx, synthesis_id

    new_cells = active_nodes.map creator
    new_cells.map process_subscribe

    # debug "Cells synthesis completed in #{new Date - START_TIME}ms."

X =
    get_cells: -> (lazy_init_state (get_state MY_STATE)).CELLS

    get_cell: get_cell

    forget_cell: (id) ->
        swap_state MY_STATE, (old_state) ->
            new_state = lazy_init_state old_state
            delete new_state.CELLS[id]
            new_state

    start_synthesis: (root_node, default_protocols) ->
        # Entry point
        unless root_node
            error "Root node not specified"
            throw "Root node not specified"

        info 'Synthesis started'

        ctx = 
            dom_parser: (dispatch_impl 'IDom', root_node)
            default_protocols: default_protocols

        observe_dom_added root_node, (new_dom) ->
            setTimeout(
                -> (synthesize_node {dom_parser: (dispatch_impl 'IDom', new_dom),\
                                     default_protocols: default_protocols})
                10
            )

        synthesize_node ctx

    synthesize_node: (node, default_protocols) ->
        synthesize_node {dom_parser: (dispatch_impl 'IDom', node), default_protocols: default_protocols}


    get_bound_method: (cell, method_proto, method_name) ->
        method_inv = cell.receptors[method_name]
        throw "No method #{method_name}@#{cell.id}" unless method_inv

        if method_proto is undefined and method_inv.length is 1
            method_inv[0].impl
        else
            method_impl = method_inv.filter (m) -> m.ns is method_proto
            throw "No method #{method_proto}/#{method_name}@#{cell.id}" unless method_impl.length is 1
            method_impl[0].impl

    call: (mspec, args...) ->
        [meth_spec, cellid] = mspec.split '@'
        [ns, meth_name] = meth_spec.split '/'

        m = X.get_bound_method (X.get_cell cellid), ns, meth_name
        m args...

module.exports = X
