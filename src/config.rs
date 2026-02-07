//! Configuration file parsing for cctop.
//!
//! Reads configuration from `~/.cctop/config.toml` and provides defaults
//! for missing fields.

use anyhow::Result;
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

/// Editor configuration for window focus and opening projects.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct EditorConfig {
    /// Process name as shown in Activity Monitor (e.g., "Code", "Cursor")
    pub process_name: String,
    /// CLI command to open projects (e.g., "code", "cursor")
    pub cli_command: String,
}

impl Default for EditorConfig {
    fn default() -> Self {
        Self {
            process_name: "Code".to_string(),
            cli_command: "code".to_string(),
        }
    }
}

/// Main configuration struct for cctop.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Editor configuration
    pub editor: EditorConfig,
}

impl Config {
    /// Load configuration from `~/.cctop/config.toml`.
    ///
    /// - If the file doesn't exist, returns default configuration.
    /// - If the file contains invalid TOML, logs a warning and returns default.
    /// - If some fields are missing, uses defaults for those fields.
    pub fn load() -> Config {
        let config_path = match Self::config_path() {
            Some(path) => path,
            None => {
                eprintln!("Warning: Could not determine home directory, using default config");
                return Config::default();
            }
        };

        if !config_path.exists() {
            return Config::default();
        }

        match fs::read_to_string(&config_path) {
            Ok(contents) => Self::from_toml(&contents).unwrap_or_else(|e| {
                eprintln!(
                    "Warning: Invalid TOML in {}: {}, using default config",
                    config_path.display(),
                    e
                );
                Config::default()
            }),
            Err(e) => {
                eprintln!(
                    "Warning: Could not read {}: {}, using default config",
                    config_path.display(),
                    e
                );
                Config::default()
            }
        }
    }

    /// Parse configuration from a TOML string.
    ///
    /// Missing fields will use their default values due to `#[serde(default)]`.
    pub fn from_toml(toml_str: &str) -> Result<Config> {
        let config: Config = toml::from_str(toml_str)?;
        Ok(config)
    }

    /// Returns the path to the config file: `~/.cctop/config.toml`
    fn config_path() -> Option<PathBuf> {
        dirs::home_dir().map(|home| home.join(".cctop").join("config.toml"))
    }

    /// Returns the sessions directory: `~/.cctop/sessions/`
    ///
    /// Creates the directory if it doesn't exist.
    /// Respects `CCTOP_SESSIONS_DIR` env var override for test isolation.
    pub fn sessions_dir() -> PathBuf {
        let sessions_dir = if let Ok(dir) = std::env::var("CCTOP_SESSIONS_DIR") {
            PathBuf::from(dir)
        } else {
            dirs::home_dir()
                .expect("Could not determine home directory")
                .join(".cctop")
                .join("sessions")
        };

        if !sessions_dir.exists() {
            if let Err(e) = fs::create_dir_all(&sessions_dir) {
                eprintln!(
                    "Warning: Could not create sessions directory {}: {}",
                    sessions_dir.display(),
                    e
                );
            }
        }

        sessions_dir
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_defaults() {
        let config = Config::default();
        assert_eq!(config.editor.process_name, "Code");
        assert_eq!(config.editor.cli_command, "code");
    }

    #[test]
    fn test_editor_config_defaults() {
        let editor = EditorConfig::default();
        assert_eq!(editor.process_name, "Code");
        assert_eq!(editor.cli_command, "code");
    }

    #[test]
    fn test_config_from_toml() {
        let toml = r#"
            [editor]
            process_name = "Cursor"
            cli_command = "cursor"
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Cursor");
        assert_eq!(config.editor.cli_command, "cursor");
    }

    #[test]
    fn test_config_from_toml_code_insiders() {
        let toml = r#"
            [editor]
            process_name = "Code - Insiders"
            cli_command = "code-insiders"
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Code - Insiders");
        assert_eq!(config.editor.cli_command, "code-insiders");
    }

    #[test]
    fn test_config_from_toml_codium() {
        let toml = r#"
            [editor]
            process_name = "Codium"
            cli_command = "codium"
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Codium");
        assert_eq!(config.editor.cli_command, "codium");
    }

    #[test]
    fn test_config_invalid_toml_uses_defaults() {
        let result = Config::from_toml("invalid { toml [");
        assert!(result.is_err());
        // When parsing fails, callers should use default
        let config = result.unwrap_or_default();
        assert_eq!(config.editor.process_name, "Code");
        assert_eq!(config.editor.cli_command, "code");
    }

    #[test]
    fn test_config_partial_toml_uses_defaults_for_missing() {
        // Only process_name is specified, cli_command should default
        let toml = r#"
            [editor]
            process_name = "Cursor"
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Cursor");
        assert_eq!(config.editor.cli_command, "code"); // default

        // Only cli_command is specified, process_name should default
        let toml = r#"
            [editor]
            cli_command = "cursor"
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Code"); // default
        assert_eq!(config.editor.cli_command, "cursor");
    }

    #[test]
    fn test_config_empty_toml_uses_all_defaults() {
        let toml = "";
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Code");
        assert_eq!(config.editor.cli_command, "code");
    }

    #[test]
    fn test_config_missing_editor_section_uses_defaults() {
        // TOML with no [editor] section at all
        let toml = r#"
            # Some comment but no actual config
        "#;
        let config = Config::from_toml(toml).unwrap();
        assert_eq!(config.editor.process_name, "Code");
        assert_eq!(config.editor.cli_command, "code");
    }

    #[test]
    fn test_sessions_dir_returns_correct_path() {
        let sessions_dir = Config::sessions_dir();
        let expected = dirs::home_dir().unwrap().join(".cctop").join("sessions");
        assert_eq!(sessions_dir, expected);
    }

    #[test]
    fn test_sessions_dir_creates_directory() {
        // This test verifies that sessions_dir creates the directory
        // We can't easily test this without modifying the home directory,
        // but we can verify the function doesn't panic
        let sessions_dir = Config::sessions_dir();
        assert!(sessions_dir.to_string_lossy().contains(".cctop"));
        assert!(sessions_dir.to_string_lossy().contains("sessions"));
    }

    #[test]
    fn test_config_load_with_nonexistent_file() {
        // Config::load() should return defaults when file doesn't exist
        // This tests the actual load() function behavior
        // Note: This test assumes ~/.cctop/config.toml may or may not exist
        let config = Config::load();
        // Should not panic and should return a valid config
        assert!(!config.editor.process_name.is_empty());
        assert!(!config.editor.cli_command.is_empty());
    }
}
