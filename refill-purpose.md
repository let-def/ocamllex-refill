The patch introduces a new "refill" action associated to a lexing rule.
It's optional and if unused the lexer specification and behavior are unchanged.

When specified, it allows the user to control the way the lexer is
refilled. For example, an appropriate refill handler could perform
the blocking operations of refilling under a concurrency monad such
as `Lwt` or `Async`, to work better in a cooperative concurrency
setting.

To make use of this feature, add

    refill {refill_function}

between the header and the first rule.

### General idea

`refill_function` is a function which will be invoked by the lexer
immediately before refilling the buffer. The function will receive as
arguments the continuation to invoke to resume the lexing, and the current
lexing buffer.

More precisely, it's a function of type:

    (Lexing.lexbuf -> 'a) ->
     Lexing.lexbuf -> 'a

where:
- the first argument is the continuation which captures the processing
  ocamllex would usually perform (refilling the buffer, then calling the lexing
  function again),
- the result type `'a` should unify with the result types of all rules.

### Anatomy of generated lexers

Let's start from a simple lexer summing all numbers found in input:

```ocaml
rule main counter = parse
  | (['0'-'9']+ as num) 
    { counter := !counter + int_of_string num;
      main counter lexbuf
    }
  | eof { !counter }
  | _ { main counter lexbuf }
```

#### C engine

The code generated for the rule looks like:

```ocaml
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
```

1. the `main` function only purpose is to invoke `__ocaml_lex_main_rec`
starting from the initial state.
2. the `__ocaml_lex_main_rec` function first calls the lexing engine then
dispatches on its result:
- in terminal states, user actions are executed
- in other states, first the buffer gets refilled then the code loops

Let's change it to include some refill action:

```ocaml
refill 
  { fun k lexbuf -> 
    prerr_endline "let's refill!";
    k lexbuf
  }

rule main counter = 
  parse
  | (['0'-'9']+ as num) 
    { counter := !counter + int_of_string num;
      main counter lexbuf
    }
  | eof { !counter }
  | _ { main counter lexbuf }
```

The generated code now looks like:

```ocaml
let __ocaml_lex_refill : (Lexing.lexbuf -> 'a) -> (Lexing.lexbuf -> 'a) =
  ( fun k lexbuf -> 
    prerr_endline "let's refill!";
    k lexbuf
  )

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
    | __ocaml_lex_state -> __ocaml_lex_refill 
        (fun lexbuf -> lexbuf.Lexing.refill_buff lexbuf; 
           __ocaml_lex_main_rec counter lexbuf __ocaml_lex_state) lexbuf
```

1. The refill handler is bound to a lexer private name.
2. The rule entry is unchanged.
3. The refill case pass the actual refilling code as an argument to the
   refill handler.

#### ML engine

The ML generator first generates some generic definitions, notably:

```ocaml
val __ocaml_lex_next_char : Lexing.lexbuf -> int
```

This function is responsible for returning the next character from the lexbuf.
If the buffer needs refill, then `__ocaml_lex_next_char` calls `refill_buff`
and retry. If the buffer reached eof, then the function return `256`.

Then, it generates the automaton as a group of mutually recursive functions.
Only shifting states call the `__ocaml_lex_next_char` function.

```ocaml
let rec __ocaml_lex_state0 lexbuf = match __ocaml_lex_next_char lexbuf with
  |256 -> 
    __ocaml_lex_state2 lexbuf
  |48|49|50|51|52|53|54|55|56|57 ->
    __ocaml_lex_state3 lexbuf
  | _ -> 
    __ocaml_lex_state1 lexbuf

and __ocaml_lex_state1 lexbuf = 2

and ...
```

The result of the automaton is an integer against which the main rule will
dispatch to execute the relevant action.

```ocaml
let rec main counter lexbuf =
  __ocaml_lex_init_lexbuf lexbuf 0; 
  let __ocaml_lex_result = __ocaml_lex_state0 lexbuf in
  ... (* dispatch against __ocaml_lex_result *)
```

Now in the refilling case:
- the same `__ocaml_lex_refill` as above is outputed,
- a new exception is defined:  
  `exception Ocaml_lex_refill of (Lexing.lexbuf -> int)`
- `__ocaml_lex_next_char` is modified, so that refill cases no longer loop
  but just returns `-1`
- the automaton states now have a special transition on `-1`: raising
  `Ocaml_lex_refill <current-state>`
- the entry of a rule initialize the buffer then jumps to
  dedicated function executing the automaton while catching this exception and
  calling the refill handler appropriately.

```ocaml
let rec __ocaml_lex_state0 lexbuf = match __ocaml_lex_next_char lexbuf with
  | -1 -> 
    raise (Ocaml_lex_refill __ocaml_lex_state0)
  |256 -> 
    __ocaml_lex_state2 lexbuf
  |48|49|50|51|52|53|54|55|56|57 ->
    __ocaml_lex_state3 lexbuf
  | _ -> 
    __ocaml_lex_state1 lexbuf

and __ocaml_lex_state1 lexbuf = 2

and ...

let rec main counter lexbuf =
  __ocaml_lex_init_lexbuf lexbuf 0; 
  __ocaml_lex_main_rec __ocaml_lex_state0 counter lexbuf

and __ocaml_lex_main_rec __ocaml_lex_state counter lexbuf =
  try
    let __ocaml_lex_result = __ocaml_lex_state0 lexbuf in
    ... (* dispatch against __ocaml_lex_result *)
  with Ocaml_lex_refill __ocaml_lex_state ->
    __ocaml_lex_refill 
      (fun lexbuf -> __ocaml_lex_main_rec __ocaml_lex_state counter lexbuf)
      lexbuf
```

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

The runtime cost close to zero.

### Testing separately

The repository <https://github.com/def-lkb/ocamllex> provides a standalone version
of ocamllex with this extension and is otherwise completely compatible with
ocaml 4.01 ocamllex.
