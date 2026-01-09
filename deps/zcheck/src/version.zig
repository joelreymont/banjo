//! Version information for zcheck.
//!
//! Build-time values are injected via build_options.

const build_options = @import("build_options");

/// Semantic version (major.minor.patch)
pub const semver = build_options.version;

/// Git commit short hash
pub const git_hash = build_options.git_hash;

/// Full version string: "0.1.0 (abc1234)"
pub const full = semver ++ " (" ++ git_hash ++ ")";
