//! Popup state management for the cctop menubar.
//!
//! Tracks popup visibility for the egui popup window.

/// State for the popup window.
#[derive(Debug, Default)]
pub struct PopupState {
    /// Whether the popup is currently visible.
    pub visible: bool,
}

impl PopupState {
    /// Create a new popup state.
    pub fn new() -> Self {
        Self::default()
    }

    /// Show the popup.
    pub fn show(&mut self) {
        self.visible = true;
    }

    /// Hide the popup.
    pub fn hide(&mut self) {
        self.visible = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_popup_state_default() {
        let state = PopupState::new();
        assert!(!state.visible);
    }

    #[test]
    fn test_popup_state_show_hide() {
        let mut state = PopupState::new();

        state.show();
        assert!(state.visible);

        state.hide();
        assert!(!state.visible);
    }
}
