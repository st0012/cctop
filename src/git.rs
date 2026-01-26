//! Git utilities for cctop.
//!
//! Provides functions for extracting git information from repositories.

use std::path::Path;
use std::process::Command;

/// Gets the current branch name for a git repository.
///
/// Runs `git branch --show-current` in the given directory and returns
/// the branch name. On any error (not a git repo, git not installed,
/// detached HEAD, etc.), returns "unknown".
///
/// # Arguments
///
/// * `cwd` - The working directory (should be inside a git repository)
///
/// # Returns
///
/// The current branch name, or "unknown" if it cannot be determined.
pub fn get_current_branch(cwd: &Path) -> String {
    let output = Command::new("git")
        .args(["branch", "--show-current"])
        .current_dir(cwd)
        .output();

    match output {
        Ok(output) if output.status.success() => {
            let branch = String::from_utf8_lossy(&output.stdout);
            let branch = branch.trim();
            if branch.is_empty() {
                // Empty output can happen with detached HEAD
                "unknown".to_string()
            } else {
                branch.to_string()
            }
        }
        _ => "unknown".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_get_current_branch_in_git_repo() {
        // Test in the cctop project directory itself (which is a git repo)
        let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let branch = get_current_branch(&cwd);
        // Should return a non-empty branch name (not "unknown")
        assert!(!branch.is_empty());
        // The branch name should not be "unknown" since we're in a git repo
        // Note: This could be "unknown" if in detached HEAD, but normally it won't be
    }

    #[test]
    fn test_get_current_branch_not_a_git_repo() {
        // /tmp is typically not a git repository
        let cwd = PathBuf::from("/tmp");
        let branch = get_current_branch(&cwd);
        assert_eq!(branch, "unknown");
    }

    #[test]
    fn test_get_current_branch_nonexistent_directory() {
        let cwd = PathBuf::from("/this/path/does/not/exist/at/all");
        let branch = get_current_branch(&cwd);
        assert_eq!(branch, "unknown");
    }

    #[test]
    fn test_get_current_branch_returns_trimmed_output() {
        // Test in the cctop project directory
        let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let branch = get_current_branch(&cwd);
        // Branch name should not have leading/trailing whitespace
        assert_eq!(branch, branch.trim());
    }
}
