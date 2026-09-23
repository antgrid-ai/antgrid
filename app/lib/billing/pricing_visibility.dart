/// Whether the app may point anyone at a paid plan: the Settings BILLING
/// section, the account menu's upgrade item, the Handler refusal's plan pitch
/// and the jumps to the pricing screen after a refusal.
///
/// Off while the store listings say there is no pricing yet — App Store review
/// rejects a build that offers plans its listing denies. Flip it on once paid
/// plans are announced; every gated site reads this one constant.
const kPricingSurfacesEnabled = false;
