//! Menubar module for cctop.
//!
//! Provides menu building functionality for the macOS menubar app.

#[cfg(target_os = "macos")]
pub mod app;

#[cfg(target_os = "macos")]
pub mod menu;

#[cfg(target_os = "macos")]
pub mod popup;

#[cfg(target_os = "macos")]
pub mod popup_state;

#[cfg(target_os = "macos")]
pub mod renderer;
