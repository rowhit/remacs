//! Generic Lisp eval macros.

/*
 * N.B. Wherever unsafe occurs in this file the line should be preceded
 * by `#[allow(unused_unsafe)]`. This allows the macro to be called
 * from within an `unsafe` block without the compiler complaining that
 * the unsafe is not used.
 */

/// Macro to generate an error with a list from any number of arguments.
/// Replaces xsignal0, etc. in the C layer.
///
/// Like `Fsignal`, but never returns. Can be used for any error
/// except `Qquit`, which can return from `Fsignal`. See the elisp docstring
/// for `signal` for an explanation of the arguments.
macro_rules! xsignal {
    ($symbol:expr) => {
        #[allow(unused_unsafe)]
        unsafe {
            ::remacs_sys::Fsignal($symbol, ::remacs_sys::Qnil);
        }
    };
    ($symbol:expr, $($tt:tt)+) => {
        #[allow(unused_unsafe)]
        unsafe {
            ::remacs_sys::Fsignal($symbol, list!($($tt)+).to_raw());
        }
    };
}

/// Macro to call Lisp functions with any number of arguments.
/// Replaces call0, call1, etc. in the C layer.
macro_rules! call {
    ($func:expr, $($arg:expr),*) => {{
        let mut argsarray = [$func.to_raw(), $($arg.to_raw()),*];
        #[allow(unused_unsafe)]
        unsafe {
            LispObject::from_raw(
                ::remacs_sys::Ffuncall(argsarray.len() as ::libc::ptrdiff_t, argsarray.as_mut_ptr())
            )
        }
    }}
}

macro_rules! call_raw {
    ($func:expr, $($arg:expr),*) => {{
        let mut argsarray = [$func, $($arg),*];
        #[allow(unused_unsafe)]
        unsafe {
            LispObject::from_raw(
                ::remacs_sys::Ffuncall(argsarray.len() as ::libc::ptrdiff_t, argsarray.as_mut_ptr())
            )
        }
    }};
    ($func:expr) => {{
        #[allow(unused_unsafe)]
        unsafe {
            LispObject::from_raw(::remacs_sys::Ffuncall(1, &mut $func))
        }
    }}
}

macro_rules! callN_raw {
    ($func:expr, $($arg:expr),*) => {{
        let mut argsarray = [$($arg),*];
        #[allow(unused_unsafe)]
        unsafe {
            LispObject::from_raw(
                $func(argsarray.len() as ::libc::ptrdiff_t, argsarray.as_mut_ptr())
            )
        }
    }}
}

macro_rules! message_with_string {
    ($str:expr, $obj:expr, $should_log:expr) => {
        #[allow(unused_unsafe)]
        unsafe {
            ::remacs_sys::message_with_string($str.as_ptr() as *const ::libc::c_char,
                                              $obj.to_raw(),
                                              $should_log);
        }
    }
}

/// Macro to format an error message.
/// Replaces error() in the C layer.
macro_rules! error {
    ($str:expr) => {{
        #[allow(unused_unsafe)]
        let strobj = unsafe {
            ::remacs_sys::make_string($str.as_ptr() as *const ::libc::c_char,
                                      $str.len() as ::libc::ptrdiff_t)
        };
        xsignal!(::remacs_sys::Qerror, $crate::lisp::LispObject::from_raw(strobj));
    }};
    ($fmtstr:expr, $($arg:expr),*) => {{
        let formatted = format!($fmtstr, $($arg),*);
        #[allow(unused_unsafe)]
        let strobj = unsafe {
            ::remacs_sys::make_string(formatted.as_ptr() as *const ::libc::c_char,
                                      formatted.len() as ::libc::ptrdiff_t)
        };
        xsignal!(::remacs_sys::Qerror, $crate::lisp::LispObject::from_raw(strobj));
    }};
}

/// Macro to format a "wrong argument type" error message.
macro_rules! wrong_type {
    ($pred:expr, $arg:expr) => {
        xsignal!(::remacs_sys::Qwrong_type_argument, LispObject::from_raw($pred), $arg);
    };
}

macro_rules! args_out_of_range {
    ($($tt:tt)+) => { xsignal!(::remacs_sys::Qargs_out_of_range, $($tt)+); };
}

macro_rules! list {
    ($arg:expr, $($tt:tt)+) => { $crate::lisp::LispObject::cons($arg, list!($($tt)+)) };
    ($arg:expr) => { $crate::lisp::LispObject::cons($arg, list!()) };
    () => { $crate::lisp::LispObject::constant_nil() };
}

/// Macro that expands to nothing, but is used at build time to
/// generate the starting symbol table. Equivalent to the DEFSYM
/// macro. See also lib-src/make-docfile.c
macro_rules! def_lisp_sym {
    ($name:expr, $value:expr) => {};
}

#[allow(unused_macros)]
macro_rules! declare_GC_protected_static {
    ($var: ident, $value: expr) => {
        static mut $var: LispObject = $value;
    }
}

macro_rules! verify_lisp_type {
    ($obj:expr, Qarrayp) => {
        if !$obj.is_array() {
            wrong_type!(::remacs_sys::Qarrayp, $obj);
        }
    };
    ($n:expr, Qcharacterp) => {
        if $n < 0 || $n > ($crate::multibyte::MAX_CHAR as EmacsInt) {
            wrong_type!(::remacs_sys::Qcharacterp, $crate::lisp::LispObject::from($n));
        }
    };
    ($obj:expr, Qstringp) => {
        if !$obj.is_string() {
            wrong_type!(::remacs_sys::Qstringp, $obj);
        }
    };
}

/// Get the index of `ident` into buffer's `local_flags` array. This
/// value will be stored in the variable `buffer_local_flags` of type
/// buffer

// This is equivalent to C's PER_BUFFER_VAR_IDX
macro_rules! per_buffer_var_idx {
    ($field: ident) => {
        #[allow(unused_unsafe)]
        ($crate::lisp::LispObject::from_raw(
            unsafe{buffer_local_flags.$field})).as_natnum_or_error() as usize
    }
}
