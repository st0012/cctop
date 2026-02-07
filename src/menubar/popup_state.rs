//! Popup state management for the cctop menubar.
//!
//! Tracks popup visibility and timing for the egui popup window.

use std::time::{Duration, Instant};

/// State for the popup window.
#[derive(Debug, Default)]
pub struct PopupState {
    /// Whether the popup is currently visible.
    pub visible: bool,
    /// When the popup was last shown (for focus-dismiss debounce).
    shown_at: Option<Instant>,
}

impl PopupState {
    /// Create a new popup state.
    pub fn new() -> Self {
        Self::default()
    }

    /// Show the popup.
    pub fn show(&mut self) {
        self.visible = true;
        self.shown_at = Some(Instant::now());
    }

    /// Hide the popup.
    pub fn hide(&mut self) {
        self.visible = false;
        self.shown_at = None;
    }

    /// Returns how long the popup has been visible, or zero if hidden.
    pub fn visible_duration(&self) -> Duration {
        self.shown_at.map(|t| t.elapsed()).unwrap_or(Duration::ZERO)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_popup_state_default() {
        let state = PopupState::new();
        assert!(!state.visible);
        assert_eq!(state.visible_duration(), Duration::ZERO);
    }

    #[test]
    fn test_popup_state_show_hide() {
        let mut state = PopupState::new();

        state.show();
        assert!(state.visible);
        assert!(state.visible_duration() >= Duration::ZERO);

        state.hide();
        assert!(!state.visible);
        assert_eq!(state.visible_duration(), Duration::ZERO);
    }
}
