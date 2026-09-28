; ==============================================================================
; Antigravity OS - JavaScript engine: shared definitions
; ------------------------------------------------------------------------------
; Pipeline: source -> lexer.asm (tokens) -> parser.asm (syntax tree + scopes)
; -> compiler.asm (bytecode) -> vm.asm (interpreter). Values, strings and
; objects live in heap.asm / object.asm, numbers in number.asm, the global
; object and native functions in builtins.asm. js.asm is the public API.
;
; Values are 64-bit and NaN-boxed: every bit pattern whose top 16 bits are
; below 0xFFF9 is an IEEE double; the rest carry a tag in the top 16 bits:
;   0xFFF9  specials: undefined, null, false, true, hole (low bits)
;   0xFFFA  string, low 32 bits = pointer to a heap string
;   0xFFFB  object, low 32 bits = pointer to a heap object
; The heap is below 4 GB, so a pointer is the low 32 bits (mov eax, eax).
;
; XMM registers are scratch everywhere (nothing else in the kernel uses them);
; general-purpose registers follow docs/CONVENTIONS.md.
; ==============================================================================

; --- Values -------------------------------------------------------------------
JS_TAG_SPECIAL          equ 0xFFF9
JS_TAG_STRING           equ 0xFFFA
JS_TAG_OBJECT           equ 0xFFFB
JS_UNDEF                equ 0xFFF9000000000000
JS_NULL                 equ 0xFFF9000000000001
JS_FALSE                equ 0xFFF9000000000002
JS_TRUE                 equ 0xFFF9000000000003
JS_HOLE                 equ 0xFFF9000000000004  ; missing array element
JS_STR_BITS             equ 0xFFFA000000000000
JS_OBJ_BITS             equ 0xFFFB000000000000
JS_TAG_SYMBOL           equ 0xFFFC      ; a symbol: a permanent JK_SYMBOL block (iter.asm)
JS_SYM_BITS             equ 0xFFFC000000000000
JS_NAN                  equ 0x7FF8000000000000
JS_INF                  equ 0x7FF0000000000000
JS_ONE                  equ 0x3FF0000000000000

; --- Heap cells: common header ------------------------------------------------
JH_KIND                 equ 0           ; byte, JK_*
JH_FLAGS                equ 1           ; byte
JH_AUX                  equ 2           ; word (strings: keyword id)

JK_STRING               equ 1
JK_OBJECT               equ 2
JK_ARRAY                equ 3
JK_FUNC                 equ 4           ; function written in JavaScript
JK_NATIVE               equ 5           ; function implemented in the kernel
JK_ENV                  equ 6           ; captured variables of a scope
JK_CODE                 equ 7           ; compiled function (template)
JK_ITER                 equ 8           ; for-in / for-of state
JK_ACCESSOR             equ 9           ; a getter/setter pair (JPA_ACCESSOR properties)
JK_CORO                 equ 10          ; a suspended async function or generator (async.asm)
JK_SYMBOL               equ 11          ; a symbol (iter.asm); usable as a property key

; Strings: bytes (UTF-8 passes through), NUL-terminated for convenience
JSTR_LEN                equ 4           ; dword
JSTR_HASH               equ 8           ; dword, 0 = not computed yet
JSTR_NEXT               equ 12          ; dword, next atom in the hash bucket
JSTR_DATA               equ 16
JSF_ATOM                equ 1           ; interned (JH_FLAGS)

; Objects (every object kind starts like this)
JOBJ_COUNT              equ 4           ; dword, property slots used (incl. deleted)
JOBJ_CAP                equ 8           ; dword, property slots allocated
JOBJ_CLASS              equ 12          ; dword, JC_*
JOBJ_PROPS              equ 16          ; qword, -> property entries
JOBJ_PROTO              equ 24          ; qword, prototype object pointer or 0
JOBJ_SIZE               equ 32
JC_PLAIN                equ 0
JC_ARGUMENTS            equ 1
JC_MATH                 equ 2
JC_GLOBAL               equ 3
JC_CONSOLE              equ 4
JC_ERROR                equ 5           ; made by Error / TypeError / ... (or thrown by the engine)
JC_PROMISE              equ 6           ; a Promise (JPROM_* fields, async.asm)
JC_ITERATOR             equ 7           ; an array / string / Map / Set iterator (JIO_*, iter.asm)
JC_GENERATOR            equ 8           ; a generator object (JGEN_*, iter.asm)
JC_MAP                  equ 9           ; Map (JMAP_*, collections.asm)
JC_SET                  equ 10
JC_WEAKMAP              equ 11
JC_WEAKSET              equ 12
JC_REGEXP               equ 13          ; a RegExp (JRE_*, regexp2.asm)
JC_DATE                 equ 14          ; a Date (JDATE_TIME, date.asm)
JC_HOST                 equ 16          ; classes from here on are host objects (jsdom.asm)
JC_NODE                 equ 16          ; a DOM node (JSD_NODE = its index)
JC_STYLE                equ 17          ; element.style
JC_CLASSLIST            equ 18          ; element.classList
JC_LOCATION             equ 19          ; window.location
JSD_NODE                equ 32          ; dword: node index in a host object
JSD_SIZE                equ 40

; Property entry: key = atom pointer in the low 32 bits, attributes above.
; A deleted entry has key 0.
JPE_KEY                 equ 0
JPE_VAL                 equ 8
JPE_SIZE                equ 16
JPA_HIDDEN              equ 1           ; not enumerable (attribute bits, key >> 32)
JPA_READONLY            equ 2
JPA_ACCESSOR            equ 4           ; the value is a JK_ACCESSOR cell (raw pointer)
JPA_FIXED               equ 8           ; not configurable: cannot be deleted
JACC_GET                equ 8           ; qword: getter function or undefined
JACC_SET                equ 16          ; qword: setter
JACC_SIZE               equ 24

; Arrays
JARR_ELEMS              equ 32          ; qword, -> values
JARR_LEN                equ 40          ; dword
JARR_CAP                equ 44          ; dword
JARR_SIZE               equ 48
JARR_MAX                equ 0x00400000  ; largest dense length; higher indices are plain properties

; Functions (JK_FUNC and JK_NATIVE)
JFN_CODE                equ 32          ; qword, JK_CODE template (JK_FUNC)
JFN_NATIVE              equ 32          ; qword, routine address (JK_NATIVE)
JFN_ENV                 equ 40          ; qword, enclosing environment (JK_FUNC)
JFN_NARGS               equ 40          ; dword, declared argument count (JK_NATIVE)
JFN_NAME                equ 48          ; qword, name atom (JK_NATIVE)
JFN_THIS                equ 48          ; qword, `this` an arrow function keeps (JK_FUNC)
JFN_PROTO_OBJ           equ 56          ; qword, the .prototype object once made
JFN_DATA                equ 56          ; qword, a native's own data (bound functions)
JFN_HOME                equ 64          ; qword, object a method belongs to (super), raw
JFN_SIZE                equ 72

; Environments (variables captured by inner functions)
JENV_COUNT              equ 4           ; dword
JENV_PARENT             equ 8           ; qword
JENV_VALS               equ 16

; Compiled function templates
JCODE_FLAGS             equ 1           ; byte, JCF_*
JCODE_NPARAMS           equ 2           ; word
JCODE_LEN               equ 4           ; dword, bytecode length
JCODE_CODE              equ 8           ; qword, -> bytecode
JCODE_NLOCALS           equ 16          ; dword, stack slots (params first)
JCODE_NENV              equ 20          ; dword, function-scope env size (JCF_HEAPENV)
JCODE_NAME              equ 24          ; qword, name atom or 0
JCODE_ARGSLOT           equ 32          ; dword, slot of `arguments` (JCF_ARGUMENTS)
JCODE_SELFSLOT          equ 36          ; dword, slot of its own name (JCF_SELF)
JCODE_LINE              equ 40          ; dword, line of the `function` keyword
JCODE_RESTSLOT          equ 44          ; dword, slot of a ...rest parameter (JCF_REST)
JCODE_FLAGS2            equ 48          ; dword, JCF2_*
JCODE_SIZE              equ 56
JCF_HEAPENV             equ 1           ; variables live in a heap env (has inner functions)
JCF_ARGUMENTS           equ 2           ; uses `arguments`
JCF_SELF                equ 4           ; named function expression binds its name
JCF_SCRIPT              equ 8           ; top-level script
JCF_ARROW               equ 16          ; arrow function: `this` from where it was made
JCF_REST                equ 32          ; has a ...rest parameter
JCF_CLASSCTOR           equ 64          ; a class constructor (only with new)
JCF_DERIVED             equ 128         ; ... of a class that extends another
JCF2_ASYNC              equ 1           ; an async function (JCODE_FLAGS2)
JCF2_GENERATOR          equ 2           ; a generator function

; Iterators (for-in / for-of)
JIT_MODE                equ 1           ; byte: JIM_*
JIT_POS                 equ 4           ; dword
JIT_SRC                 equ 8           ; qword value (JIM_PROTOCOL: the iterator)
JIT_NEXT                equ 16          ; JIM_PROTOCOL: the iterator's next method
JIT_SIZE                equ 24
JIM_ARRAY               equ 0           ; values of an array (live length)
JIM_STRING              equ 1           ; characters of a string
JIM_KEYS                equ 2           ; values of a key array made by for-in
JIM_PROTOCOL            equ 3           ; iterator.next() (anything with [Symbol.iterator])

; --- Call frames (JS_FRAMES_ADDR) ---------------------------------------------
JFR_PC                  equ 0           ; caller's pc
JFR_BASE                equ 8           ; caller's locals base
JFR_FUNC                equ 16          ; caller's function object
JFR_ENV                 equ 24          ; caller's environment
JFR_RESULT              equ 32          ; where the result goes (callee slot)
JFR_FLAGS               equ 40          ; dword, JFRF_*
JFR_LINE                equ 44          ; dword, caller's current line
JFR_CORO                equ 48          ; an async function's coroutine (JFRF_ASYNC)
JFR_SIZE                equ 56
JFRF_BOUNDARY           equ 1           ; return leaves vm_run (js_call)
JFRF_CONSTRUCT          equ 2           ; `new`: a non-object result becomes `this`
JFRF_ASYNC              equ 4           ; an async function: returns settle its promise
JFRF_GEN                equ 8           ; a generator: returning finishes it

; --- Errors (js_throw) --------------------------------------------------------
JE_ERROR                equ 0
JE_TYPE                 equ 1
JE_REFERENCE            equ 2
JE_SYNTAX               equ 3
JE_RANGE                equ 4
JE_COUNT                equ 5

; --- Exception handlers (TRY .. ENDTRY) ---------------------------------------
JTH_PC                  equ 0           ; where the catch code starts
JTH_SP                  equ 8           ; value stack, frame, environment, function
JTH_BASE                equ 16
JTH_ENV                 equ 24
JTH_FUNC                equ 32
JTH_FP                  equ 40
JTH_RSP                 equ 48          ; kernel stack of that vm_run
JTH_NEST                equ 56          ; dword, vm_nesting then
JTH_DEPTH               equ 60          ; dword, js_depth then (js_eval / js_call_safe level)
JTH_SIZE                equ 64
JSVM_MAX_HANDLERS       equ 256

; --- Macros -------------------------------------------------------------------
; JS_TAG dst64, src64: dst = tag (top 16 bits). Below JS_TAG_SPECIAL = number.
%macro JS_TAG 2
    mov %1, %2
    shr %1, 48
%endmacro

; --- Bytecode -----------------------------------------------------------------
; One byte per opcode, operands inline (little-endian). Stack effects:
;   UNDEF NULL TRUE FALSE THIS HOLE     -> v
;   NUM f64 / STR atom32               -> v
;   POP a ->  | DUP a -> a a | DUP2 a b -> a b a b | SWAP a b -> b a
;   ROT3 a b c -> c a b | ROT4 a b c d -> d a b c
;   GETLOC u16 -> v | SETLOC u16 v -> v          (stack slots of the frame)
;   GETENV u8 depth, u16 i -> v | SETENV ...     (captured variables)
;   GETGLOB atom32, cache32 -> v | SETGLOB atom32, cache32 v -> v
;   TYPEOFGLOB atom32 -> typeof name (no ReferenceError)
;   GETPROP atom32, cache32: o -> o.name | SETPROP atom32: o v -> v
;   GETELEM o k -> o[k] | SETELEM o k v -> v
;   GETMETHOD atom32: o -> f o | GETMETHODE o k -> f o
;   DELPROP atom32: o -> bool | DELELEM o k -> bool
;   CALL u8 argc, name32: f this args... -> result (NEW: same with `new`)
;   RET v | RETUNDEF
;   binary operators: a b -> r | NEG PLUS NOT BNOT TYPEOF INC DEC TONUM: a -> r
;   JMP/JF/JT rel32 (JF/JT pop the test); JFK/JTK/JNNK rel32 keep the value
;     when they jump and pop it when they do not (&&, ||, ??)
;   OBJECT -> {} | INITPROP atom32: o v -> o | INITELEM: o k v -> o
;   ARRAY -> [] | APPEND: a v -> a
;   CLOSURE code32 -> function
;   ENTERENV u16 n | LEAVEENV | COPYENV (block scopes with captured variables)
;   FORIN o -> iter | FOROF o -> iter | ITERNEXT rel32: iter -> iter v, or jump
;   THROW v | LINE u32 | COMPLETION v -> | GETCOMPL -> v | CONSTERR atom32
;   DECLGLOB atom32: defines the global as undefined unless it exists
;   TRY rel32: exceptions until the matching ENDTRY jump there (value pushed)
;   TOSTR a -> String(a) | SPREAD arr v -> arr (v's items appended)
;   OBJSPREAD o src -> o (src's own enumerable properties copied)
;   CALLA name32 / NEWA name32: f this arr -> result (the array's items are
;     the arguments)
;   JNULLISH rel32: a null/undefined top becomes undefined and jumps (?.)
;   JNULLCALL rel32: f this: f null/undefined -> undefined, jump (f?.())
;   ARRREST u32 i: v -> [v[i], v[i+1], ...]
;   OBJREST u16 n: src k1..kn -> a copy of src without those keys
;   INITGET / INITSET atom32: o f -> o (accessor in an object literal)
;   CLASS u8 flags, code32: [parent] -> constructor (flags 1: has a parent)
;   METHOD atom32, u8 kind: target f -> (kind 0 method, 1 getter, 2 setter)
;   METHODE u8 kind: target key f ->
;   SUPERFN -> the parent constructor | SUPERCALL u8 n, name32 (like CALL)
;   SUPERCALLA name32 | SUPERGET atom32 -> super.name
%macro JS_OPCODE_LIST 0
    OPC UNDEF
    OPC NULL
    OPC TRUE
    OPC FALSE
    OPC NUM
    OPC STR
    OPC THIS
    OPC HOLE
    OPC POP
    OPC DUP
    OPC DUP2
    OPC SWAP
    OPC ROT3
    OPC ROT4
    OPC GETLOC
    OPC SETLOC
    OPC GETENV
    OPC SETENV
    OPC GETGLOB
    OPC SETGLOB
    OPC TYPEOFGLOB
    OPC GETPROP
    OPC SETPROP
    OPC GETELEM
    OPC SETELEM
    OPC GETMETHOD
    OPC GETMETHODE
    OPC DELPROP
    OPC DELELEM
    OPC CALL
    OPC NEW
    OPC RET
    OPC RETUNDEF
    OPC ADD
    OPC SUB
    OPC MUL
    OPC DIV
    OPC MOD
    OPC SHL
    OPC SAR
    OPC SHR
    OPC BAND
    OPC BOR
    OPC BXOR
    OPC EQ
    OPC NE
    OPC SEQ
    OPC SNE
    OPC LT
    OPC LE
    OPC GT
    OPC GE
    OPC INSTANCEOF
    OPC IN
    OPC NEG
    OPC PLUS
    OPC NOT
    OPC BNOT
    OPC TYPEOF
    OPC INC
    OPC DEC
    OPC TONUM
    OPC JMP
    OPC JF
    OPC JT
    OPC JFK
    OPC JTK
    OPC JNNK
    OPC OBJECT
    OPC INITPROP
    OPC INITELEM
    OPC ARRAY
    OPC APPEND
    OPC CLOSURE
    OPC ENTERENV
    OPC LEAVEENV
    OPC COPYENV
    OPC FORIN
    OPC FOROF
    OPC ITERNEXT
    OPC THROW
    OPC LINE
    OPC COMPLETION
    OPC GETCOMPL
    OPC CONSTERR
    OPC DECLGLOB
    OPC POW
    OPC TRY
    OPC ENDTRY
    OPC TOSTR
    OPC SPREAD
    OPC OBJSPREAD
    OPC CALLA
    OPC NEWA
    OPC JNULLISH
    OPC JNULLCALL
    OPC ARRREST
    OPC OBJREST
    OPC INITGET
    OPC INITSET
    OPC CLASS
    OPC METHOD
    OPC METHODE
    OPC SUPERFN
    OPC SUPERCALL
    OPC SUPERCALLA
    OPC SUPERGET
    OPC ASYNCSTART
    OPC ASYNCREJECT
    OPC AWAIT
    OPC TOARRAY
    OPC GETITER
    OPC GENSTART
    OPC YIELD
    OPC YIELDSTAR
    OPC GENTHROW
    OPC REGEXP
%endmacro

%assign js_opc_n 0
%macro OPC 1
    OP_%1 equ js_opc_n
    %assign js_opc_n js_opc_n + 1
%endmacro
JS_OPCODE_LIST
%unmacro OPC 1
JS_OPCODE_COUNT         equ js_opc_n
