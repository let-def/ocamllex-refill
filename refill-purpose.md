The patch introduces a new "refill" action associated to a lexing rule.
It's optional and if unused the lexer specification and behavior are unchanged.

When specified, it allows the user to control the way the lexer is
refilled. For example, an appropriate refill handler could perform
the blocking operations of refilling under a concurrency monad such
as `Lwt` or `Async`, to work better in a cooperative concurrency
setting.

To make use of this feature, a lexing rule should be upgraded from:

    rule entry_name arg1 = parse
      | ...

to:

    rule entry_name arg1 = refill {refill_function} parse
      | ...

### General idea

`refill_function` is a function which will be invoked by the lexer
immediately before refilling the buffer. The function will receive as
arguments the continuation to invoke to resume the lexing, as well as all other
values to be passed to the continuation.

More precisely, it's a function of type:
    ('param_0 -> ... -> 'param_n -> Lexing.lexbuf -> int -> 'a) ->
     'param_0 -> ... -> 'param_n -> Lexing.lexbuf -> int -> 'a

where:
- `'param_0`, ..., `'param_n` are types of the parameters of the lexing rule
- the `int` represents the state of the lexing automaton
- the first argument is the continuation (which as the exact same type as the
  rest of the function), which captures the processing ocamllex would usually
  perform (refilling the buffer, then calling the lexing function again)

### Anatomy of generated lexers

Let's start from a simple lexer summing all numbers found in input:

    rule main counter = parse
      | (['0'-'9']+ as num) 
        { counter := !counter + int_of_string num;
          main counter lexbuf
        }
      | eof { !counter }
      | _ { main counter lexbuf }

The code generated for the rule looks like:

    let rec main counter lexbuf =
        __ocaml_lex_main_rec counter lexbuf 0
    and __ocaml_lex_main_rec counter lexbuf __ocaml_lex_state =
      match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
        | 0 ->
            let num = Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
            ( counter := !counter + int_of_string num;
              main counter lexbuf )
        | 1 -> ( !counter )
        | 2 -> ( main counter lexbuf )
        | __ocaml_lex_state -> lexbuf.Lexing.refill_buff lexbuf; __ocaml_lex_main_rec counter lexbuf __ocaml_lex_state

1. the `main` function only purpose is to invoke `__ocaml_lex_main_rec`
starting from the initial state.
2. the `__ocaml_lex_main_rec` function first calls the lexing engine then
dispatches on its result:
- in terminal states, user actions are executed
- in other states, first the buffer gets refilled then the code loops

Let's change it to include some refill action:

    rule main counter = 
      refill {fun k counter lexbuf state -> 
                prerr_endline "let's refill!";
                k counter lexbuf state}
      parse
      | (['0'-'9']+ as num) 
        { counter := !counter + int_of_string num;
          main counter lexbuf
        }
      | eof { !counter }
      | _ { main counter lexbuf }

The generated code now looks like:

    let rec main counter lexbuf =
        __ocaml_lex_main_rec counter lexbuf 0
    and __ocaml_lex_main_rec counter lexbuf __ocaml_lex_state =
      match Lexing.engine __ocaml_lex_tables __ocaml_lex_state lexbuf with
        | 0 ->
            let num = Lexing.sub_lexeme lexbuf lexbuf.Lexing.lex_start_pos lexbuf.Lexing.lex_curr_pos in
            ( counter := !counter + int_of_string num;
              main counter lexbuf )
        | 1 -> ( !counter )
        | 2 -> ( main counter lexbuf )
        | __ocaml_lex_state ->
            (fun k counter lexbuf state -> 
              prerr_endline "let's refill!";
              k counter lexbuf state)
                __ocaml_lex_main_refill 
                counter lexbuf __ocaml_lex_state
      
      and __ocaml_lex_main_refill counter lexbuf __ocaml_lex_state =
        lexbuf.Lexing.refill_buff lexbuf;
        __ocaml_lex_main_rec counter lexbuf __ocaml_lex_state

1. The first part is unchanged.
2. The refill case is now split in two parts:
   - the `__ocaml_lex_main_refill` doing the work that was previously done
     directly in the branch action: refilling buffer and looping.
   - in the branch, just call the user refill action with
     `__ocaml_lex_main_refill` as the continuation

### Design considerations

1. One may wonder why the refill action is local to a rule and not globally
applied to all rules in the file.

In a more realistic example, the action could make use of one or more of the
parameters, e.g. to access some information relative to the lexbuf, like a
rendez-vous point shared with lexbuf refilling function.

As such this action depends on the type of the rule and imposing the same to
all rules might get in the way of the user.

Also, it's likely that if someone makes multiple use of a refill action, most
of the code will be put in the prolog of the lexer and shared across different
rules.  Recalling the refill action at the beginning of each rule will
therefore be lightweight but may ease readability by making the special flow
more explicit.

2. The refill action is passed the lexbuf and the local state, exposing some
internals of the lexer.  One may argue that more safety could be added, like
passing the local state as an abstract type or wrapped in a closure.

However I believe that this choice is consistent with the rest of the ocamllex
design: the code is still simple and straightforward, internals are exposed 
when it's easier (e.g. Lexing.lexbuf type) and it's obvious that messing with
those values will lead to undesirable behaviors.

Furthermore, this choice ensures a runtime cost close to zero.

### Testing separately

The repository <https://github.com/def-lkb/ocamllex> provides a standalone version
of ocamllex with this extension and is otherwise completely compatible with
ocaml 4.01 ocamllex.
