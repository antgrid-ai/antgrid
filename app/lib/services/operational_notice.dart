/// One finished operation's outcome, as toasted by `OperationalErrorToaster`.
///
/// [failed] is carried rather than inferred from the wording: a refusal comes
/// back as whatever git or a hook printed, which reads no differently from a
/// success line, and it is the failure the user must not miss.
typedef OperationalNotice = ({String message, bool failed});
