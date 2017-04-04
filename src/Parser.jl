__precompile__()
module Parser
global debug = true

using Tokenize
import Base: next, start, done, length, first, last, +, isempty, getindex, setindex!
import Tokenize.Tokens
import Tokenize.Tokens: Token, iskeyword, isliteral, isoperator
import Tokenize.Lexers: Lexer, peekchar, iswhitespace

export ParseState, parse_expression

include("hints.jl")
import .Hints: Hint, LintCodes, FormatCodes

include("lexer.jl")
include("spec.jl")
include("utils.jl")
include("iterators.jl")
include("scoping/scoping.jl")
include("components/array.jl")
include("components/curly.jl")
include("components/operators.jl")
include("components/do.jl")
include("components/functions.jl")
include("components/genericblocks.jl")
include("components/ifblock.jl")
include("components/let.jl")
include("components/loops.jl")
include("components/generators.jl")
include("components/macros.jl")
include("components/modules.jl")
include("components/prefixkw.jl")
include("components/quote.jl")
include("components/refs.jl")
include("components/strings.jl")
include("components/tryblock.jl")
include("components/types.jl")
include("components/tuples.jl")
include("conversion.jl")
include("display.jl")


"""
    parse_expression(ps)

Parses an expression until `closer(ps) == true`. Expects to enter the 
`ParseState` the token before the the beginning of the expression and ends 
on the last token. 

Acceptable starting tokens are: 
+ A keyword
+ An opening parentheses or brace.
+ An operator.
+ An instance (e.g. identifier, number, etc.)
+ An `@`.

"""
function parse_expression(ps::ParseState)
    next(ps)
    if Tokens.begin_keywords < ps.t.kind < Tokens.end_keywords && ps.t.kind != Tokens.DO
        ret = @nocloser ps toplevel parse_kw(ps, Val{ps.t.kind})
    elseif ps.t.kind == Tokens.LPAREN
        ret = parse_paren(ps)
    elseif ps.t.kind == Tokens.LSQUARE
        ret = parse_array(ps)
    elseif isinstance(ps.t) || isoperator(ps.t)
        ret = INSTANCE(ps)
        if ret isa OPERATOR{8,Tokens.COLON} && ps.nt.kind != Tokens.COMMA
            ret = parse_unary(ps, ret)
        end
    elseif ps.t.kind==Tokens.AT_SIGN
        ret = parse_macrocall(ps)
    else
        error("Expression started with $(ps)")
    end

    while !closer(ps) && !(ps.closer.precedence == 15 && ismacro(ret))
        ret = parse_compound(ps, ret)
    end
    if ps.closer.precedence != 15 && closer(ps) && ret isa LITERAL{Tokens.MACRO}
        ret = EXPR(MACROCALL, [ret], ret.span)
    end

    return ret
end


"""
    parse_compound(ps, ret)

Handles cases where an expression - `ret` - is not followed by 
`closer(ps) == true`. Possible juxtapositions are: 
+ operators
+ `(`, calls
+ `[`, ref
+ `{`, curly
+ `,`, commas
+ `for`, generators
+ `do`
+ strings
+ an expression preceded by a unary operator
+ A number followed by an expression (with no seperating white space)
"""
function parse_compound(ps::ParseState, ret)
    if ps.nt.kind == Tokens.FOR
        ret = parse_generator(ps, ret)
    elseif ps.nt.kind == Tokens.DO
        ret = parse_do(ps, ret)
    elseif ((ret isa LITERAL{Tokens.INTEGER} || ret isa LITERAL{Tokens.FLOAT}) && (ps.nt.kind == Tokens.IDENTIFIER || ps.nt.kind == Tokens.LPAREN)) || (ret isa EXPR && ret.head isa OPERATOR{15, Tokens.PRIME} && ps.nt.kind == Tokens.IDENTIFIER) || ((ps.t.kind == Tokens.RPAREN || ps.t.kind == Tokens.RSQUARE) && ps.nt.kind == Tokens.IDENTIFIER)
        # a literal number followed by an identifier or (
        # a transpose call followed by an identifier
        # a () or [] expression followed by an identifier
        #  --> implicit multiplication
        op = OPERATOR{11,Tokens.STAR,false}(0)
        ret = parse_operator(ps, ret, op)
    elseif ps.nt.kind==Tokens.LPAREN && !(ret isa OPERATOR{9, Tokens.EX_OR})
        if isempty(ps.ws) 
            ret = @default ps @closer ps paren parse_call(ps, ret)
        else
            error("space before \"(\" not allowed in \"$(Expr(ret)) (\"")
        end
    elseif ps.nt.kind==Tokens.LBRACE
        if isempty(ps.ws)
            ret = parse_curly(ps, ret)
        else
            error("space before \"{\" not allowed in \"$(Expr(ret)) {\"")
        end
    elseif ps.nt.kind==Tokens.LSQUARE
        if isempty(ps.ws)
            ret = @nocloser ps block parse_ref(ps, ret)
        else
            error("space before \"[\" not allowed in \"$(Expr(ret)) {\"")
        end
    elseif ps.nt.kind == Tokens.COMMA
        ret = parse_tuple(ps, ret)
    elseif isunaryop(ret) && !isassignment(ps.nt)
        ret = parse_unary(ps, ret)
    elseif isoperator(ps.nt)
        next(ps)
        op = INSTANCE(ps)
        format_op(ps, precedence(ps.t))
        ret = parse_operator(ps, ret, op)
    elseif (ret isa IDENTIFIER || (ret isa EXPR && ret.head isa OPERATOR{15,Tokens.DOT})) && (ps.nt.kind == Tokens.STRING || ps.nt.kind == Tokens.TRIPLE_STRING)
        next(ps)
        arg = parse_string(ps, ret)
        ret = EXPR(x_STR, [ret, arg], ret.span + arg.span)
    elseif ret isa EXPR && ret.head == x_STR && ps.nt.kind == Tokens.IDENTIFIER
        next(ps)
        arg = INSTANCE(ps)
        push!(ret.args, LITERAL{Tokens.STRING}(arg.span, arg.val))
        ret.span += arg.span
    elseif ret isa EXPR && ret.head isa OPERATOR{20, Tokens.PRIME} 
        # prime operator followed by an identifier has an implicit multiplication
        nextarg = @precedence ps 11 parse_expression(ps)
        ret = EXPR(CALL, [OPERATOR{11, Tokens.STAR, false}(0), ret, nextarg], ret.span + nextarg.span)
    else
        println(first(stacktrace()))
        print_with_color(:green, string("Failed at: ", position(ps.l.io), "\n"))
        for f in fieldnames(ps.closer)
            if getfield(ps.closer, f)==true
                println(f, ": true")
            end
        end
        error("infinite loop at $(ps)")
    end
    return ret
end



"""
    parse_list(ps)

Parses a list of comma seperated expressions finishing when the parent state
of `ps.closer` is met, newlines are ignored. Expects to start at the first item and ends on the last
item so surrounding punctuation must be handled externally.

**NOTE**
Should be replaced with the approach taken in `parse_call`
"""
function parse_list(ps::ParseState, puncs)
    args = SyntaxNode[]

    while !closer(ps)
        a = @nocloser ps newline @closer ps comma parse_expression(ps)
        push!(args, a)
        if ps.nt.kind==Tokens.COMMA
            next(ps)
            push!(puncs, INSTANCE(ps))
            format_comma(ps)
        end
    end

    if ps.t.kind == Tokens.COMMA
        format_comma(ps)
    end
    return args
end



"""
    parse_paren(ps, ret)

Parses an expression starting with a `(`.
"""
function parse_paren(ps::ParseState)
    startbyte = ps.t.startbyte
    openparen = INSTANCE(ps)
    format_lbracket(ps)
    
    # handle empty case
    if ps.nt.kind == Tokens.RPAREN
        next(ps)
        closeparen = INSTANCE(ps)
        format_rbracket(ps)
        return EXPR(TUPLE, [], ps.nt.startbyte - startbyte, [openparen, closeparen])
    end
    
    ret = EXPR(BLOCK, [], 0)
    while ps.nt.kind != Tokens.RPAREN && ps.nt.kind !=Tokens.ENDMARKER
        a = @default ps @nocloser ps newline @closer ps paren parse_expression(ps)
        push!(ret.args, a)
    end

    if length(ret.args) == 1
        if ret.args[1] isa EXPR && ret.args[1].head isa OPERATOR{0,Tokens.DDDOT} && ps.ws.kind != SemiColonWS
            ret.args[1] = EXPR(TUPLE,[ret.args[1]], ret.args[1].span)
        end

        if ps.ws.kind != SemiColonWS
            ret.head = HEAD{InvisibleBrackets}(0)
        end
    elseif ret isa EXPR && (ret.head == TUPLE || ret.head == BLOCK)
    else
        ret = EXPR(BLOCK, [ret], 0)
    end
    # handle closing ')'
    next(ps)
    closeparen = INSTANCE(ps)
    format_rbracket(ps)
    
    unshift!(ret.punctuation, openparen)
    push!(ret.punctuation, closeparen)
    ret.span = ps.nt.startbyte - startbyte

    return ret
end




"""
    parse_quote(ps)

Handles the case where a colon is used as a unary operator on an
expression. The output is a quoted expression.
"""
function parse_quote(ps::ParseState)
    startbyte = ps.t.startbyte
    puncs = INSTANCE[INSTANCE(ps)]
    if ps.nt.kind == Tokens.IDENTIFIER
        arg = INSTANCE(next(ps))
        return QUOTENODE(arg, arg.span, puncs)
    elseif iskw(ps.nt)
        next(ps)
        arg = IDENTIFIER(ps.nt.startbyte - ps.t.startbyte, Symbol(ps.val))
        return QUOTENODE(arg, arg.span, puncs)
    elseif isliteral(ps.nt)
        return INSTANCE(next(ps))
    elseif ps.nt.kind == Tokens.LPAREN
        next(ps)
        push!(puncs, INSTANCE(ps))
        if ps.nt.kind == Tokens.RPAREN
            next(ps)
            return EXPR(QUOTE, [EXPR(TUPLE,[], 2, [pop!(puncs), INSTANCE(ps)])], 3, puncs)
        end
        arg = @closer ps paren parse_expression(ps)
        next(ps)
        push!(puncs, INSTANCE(ps))
        return EXPR(QUOTE, [arg],  ps.nt.startbyte - startbyte, puncs)
    end
end



"""
    parse(str, cont = false)

Parses the passed string. If `cont` is true then will continue parsing until the end of the string returning the resulting expressions in a TOPLEVEL block.
"""
function parse(str::String, cont = false)
    ps = Parser.ParseState(str)
    x, ps = parse(ps, cont)
    return x
end


function parse_doc(ps::ParseState, ret)
    (ps.nt.kind == Tokens.ENDMARKER) && return ret
    if ret isa LITERAL{Tokens.STRING} || ret isa LITERAL{Tokens.TRIPLE_STRING} || (ret isa EXPR && ret.head==STRING)
        doc = ret
        ret = parse_expression(ps)
        ret = EXPR(MACROCALL, [GlobalRefDOC, doc, ret], doc.span + ret.span)
    end
    return ret
end

function parse_doc(ps::ParseState)
    if ps.nt.kind == Tokens.STRING || ps.nt.kind == Tokens.TRIPLE_STRING
        next(ps)
        doc = INSTANCE(ps)
        (ps.nt.kind == Tokens.ENDMARKER) && return doc
        ret = parse_expression(ps)
        ret = EXPR(MACROCALL, [GlobalRefDOC, doc, ret], doc.span + ret.span)
    else
        ret = parse_expression(ps)
    end
    return ret
end

"""
    parse(str, cont = false)

"""
function parse(ps::ParseState, cont = false)
    if ps.l.io.size == 0
        return (cont ? EXPR(TOPLEVEL, [], 0) : nothing), ps
    end

    if cont
        top = EXPR(TOPLEVEL, [], 0)
        if ps.nt.kind == Tokens.WHITESPACE || ps.nt.kind == Tokens.COMMENT
            next(ps)
            push!(top.args, LITERAL{nothing}(ps.nt.startbyte, :nothing))
        end
        while !ps.done
            ret = parse_doc(ps)
            push!(top.args, ret)
        end
        top.span += ps.nt.startbyte
    else
        if ps.nt.kind == Tokens.WHITESPACE || ps.nt.kind == Tokens.COMMENT
            next(ps)
            top = LITERAL{nothing}(ps.nt.startbyte, :nothing)
        else
            top = parse_doc(ps)
        end
    end

    return top, ps
end


function parse_file(path::String)
    x = parse(readstring(path), true)
    
    File([], (f->joinpath(dirname(path), f)).(_get_includes(x)), path, x)
end

function parse_directory(path::String, proj = Project(path,[]))
    for f in readdir(path)
        if isfile(joinpath(path, f)) && endswith(f, ".jl")
            try
                push!(proj.files, parse_file(joinpath(path, f)))
            catch
                println("$f failed to parse")
            end
        elseif isdir(joinpath(path, f))
            parse_directory(joinpath(path, f), proj)
        end
    end
    proj
end

function parse_jmd(str)
    currentbyte = 1
    blocks = []
    ps = ParseState(str)
    while ps.nt.kind != Tokens.ENDMARKER
        next(ps)
        if ps.t.kind == Tokens.CMD || ps.t.kind == Tokens.TRIPLE_CMD
            push!(blocks, (ps.t.startbyte, INSTANCE(ps)))
        end
    end
    top = EXPR(BLOCK, [])
    if isempty(blocks)
        return top
    end

    for (startbyte, b) in blocks
        if b isa LITERAL{Tokens.TRIPLE_CMD} && (startswith(b.val, "```julia") || startswith(b.val, "```{julia"))
            blockstr = b.val[4:end-3]
            ps = ParseState(blockstr)
            while ps.nt.startpos[1]==1
                next(ps)
            end
            prec_str_size = currentbyte:startbyte + ps.nt.startbyte + 3
            push!(top.args, LITERAL{Tokens.STRING}(sizeof(str[prec_str_size]), str[prec_str_size]))
            args, ps = parse(ps, true)
            append!(top.args, args.args)
            top.span = sum(x.span for x in top)
            currentbyte = top.span+1
        elseif b isa LITERAL{Tokens.CMD} && startswith(b.val, "`j ")
            blockstr = b.val[4:end-1]
            ps = ParseState(blockstr)
            next(ps)
            prec_str_size = currentbyte:startbyte + ps.nt.startbyte + 1
            push!(top.args, LITERAL{Tokens.STRING}(sizeof(str[prec_str_size]), str[prec_str_size]))
            args, ps = parse(ps, true)
            append!(top.args, args.args)
            top.span = sum(x.span for x in top)
            currentbyte = top.span+1
        end
    end

    prec_str_size = currentbyte:sizeof(str)
    push!(top.args, LITERAL{Tokens.STRING}(sizeof(str[prec_str_size]), str[prec_str_size]))
    top.span = sum(x.span for x in top)

    return top
end

ischainable(t::Token) = t.kind == Tokens.PLUS || t.kind == Tokens.STAR || t.kind == Tokens.APPROX
LtoR(prec::Int) = 1 ≤ prec ≤ 5 || prec == 13

include("precompile.jl")
_precompile_()
end