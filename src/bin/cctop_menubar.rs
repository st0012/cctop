//! macOS menubar application for cctop with egui popup.
//!
//! Displays Claude Code session status in the system menu bar.
//! Click on a session to focus its terminal window.

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("cctop-menubar is only supported on macOS");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
fn main() {
    if let Err(e) = run_menubar() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

#[cfg(target_os = "macos")]
fn run_menubar() -> anyhow::Result<()> {
    use anyhow::Context;
    use cctop::config::Config;
    use cctop::focus::focus_terminal;
    use cctop::menubar::popup::{calculate_popup_height, render_popup, POPUP_WIDTH, QUIT_ACTION};
    use cctop::menubar::popup_state::PopupState;
    use cctop::session::Session;
    use cctop::watcher::SessionWatcher;
    use std::sync::Arc;
    use tao::dpi::{LogicalSize, PhysicalPosition};
    use tao::event::{Event, StartCause, WindowEvent};
    use tao::event_loop::{ControlFlow, EventLoop};
    use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
    use tao::window::WindowBuilder;
    use tray_icon::TrayIconBuilder;

    eprintln!("[cctop-menubar] Starting...");

    // Get sessions directory
    let sessions_dir = dirs::home_dir()
        .context("Could not determine home directory")?
        .join(".cctop")
        .join("sessions");

    // Load initial sessions
    let sessions = Session::load_all(&sessions_dir).unwrap_or_default();

    // Load config for focus_terminal
    let config = Config::load();

    // Create event loop with Accessory policy (no dock icon, menu bar only)
    let mut event_loop: EventLoop<()> = EventLoop::new();
    event_loop.set_activation_policy(ActivationPolicy::Accessory);

    // Create popup state (tracks visibility only)
    let popup_state = PopupState::new();

    // Calculate initial popup size
    let popup_height = calculate_popup_height(&sessions);

    // Create the popup window (initially hidden)
    let window = WindowBuilder::new()
        .with_title("cctop")
        .with_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64))
        .with_decorations(false)
        .with_resizable(false)
        .with_visible(false)
        .with_always_on_top(true)
        .build(&event_loop)
        .context("Failed to create popup window")?;

    // Set window level to floating (above normal windows)
    window.set_always_on_top(true);

    // Initialize wgpu
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::all(),
        ..Default::default()
    });

    // Create surface from window
    let surface = unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::from_window(&window)?)
    }?;

    // Request adapter
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::LowPower,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
    }))
    .context("Failed to find suitable GPU adapter")?;

    // Request device and queue
    let (device, queue) = pollster::block_on(adapter.request_device(
        &wgpu::DeviceDescriptor {
            label: Some("cctop device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            memory_hints: wgpu::MemoryHints::default(),
        },
        None,
    ))
    .context("Failed to create GPU device")?;

    let device = Arc::new(device);
    let queue = Arc::new(queue);

    // Configure surface - use physical pixels for wgpu
    let physical_size = window.inner_size();
    let scale_factor = window.scale_factor();

    let surface_caps = surface.get_capabilities(&adapter);
    let surface_format = surface_caps
        .formats
        .iter()
        .find(|f| f.is_srgb())
        .copied()
        .unwrap_or(surface_caps.formats[0]);

    let mut surface_config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format: surface_format,
        width: physical_size.width.max(1),
        height: physical_size.height.max(1),
        present_mode: wgpu::PresentMode::AutoVsync,
        alpha_mode: wgpu::CompositeAlphaMode::Auto,
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &surface_config);

    // Initialize egui
    let egui_ctx = egui::Context::default();

    // Set pixels_per_point for HiDPI/Retina display support
    egui_ctx.set_pixels_per_point(scale_factor as f32);

    // Configure egui style for dark theme
    let mut style = (*egui_ctx.style()).clone();
    style.visuals = egui::Visuals::dark();
    egui_ctx.set_style(style);

    // Create egui-wgpu renderer
    let mut egui_renderer =
        egui_wgpu::Renderer::new(&device, surface_format, None, 1, false);

    // Track raw input for egui - use logical pixels for screen_rect
    let mut egui_input = egui::RawInput::default();
    let logical_width = physical_size.width as f32 / scale_factor as f32;
    let logical_height = physical_size.height as f32 / scale_factor as f32;
    egui_input.screen_rect = Some(egui::Rect::from_min_size(
        egui::Pos2::ZERO,
        egui::vec2(logical_width, logical_height),
    ));

    // Store scale factor for coordinate conversion
    let mut current_scale_factor = scale_factor;

    // Warmup render to initialize GPU resources (prevents delay on first click)
    {
        let output = surface.get_current_texture()?;
        let view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());

        let input = egui_input.take();
        egui_ctx.begin_pass(input);
        render_popup(&egui_ctx, &sessions);
        let full_output = egui_ctx.end_pass();
        let paint_jobs = egui_ctx.tessellate(full_output.shapes, full_output.pixels_per_point);

        for (id, delta) in &full_output.textures_delta.set {
            egui_renderer.update_texture(&device, &queue, *id, delta);
        }

        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("warmup encoder"),
        });

        let screen_descriptor = egui_wgpu::ScreenDescriptor {
            size_in_pixels: [surface_config.width, surface_config.height],
            pixels_per_point: scale_factor as f32,
        };

        egui_renderer.update_buffers(&device, &queue, &mut encoder, &paint_jobs, &screen_descriptor);

        {
            let render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("warmup render pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            let mut render_pass = render_pass.forget_lifetime();
            egui_renderer.render(&mut render_pass, &paint_jobs, &screen_descriptor);
        }

        queue.submit(std::iter::once(encoder.finish()));
        output.present();

        for id in &full_output.textures_delta.free {
            egui_renderer.free_texture(id);
        }
    }

    // Create tray icon (no menu, we handle clicks ourselves)
    let tray_icon = TrayIconBuilder::new()
        .with_tooltip("cctop - Claude Code Sessions")
        .with_title("CC")
        .build()
        .context("Failed to create tray icon")?;

    // Store mutable state
    let sessions = std::cell::RefCell::new(sessions);
    let watcher = std::cell::RefCell::new(SessionWatcher::new().ok());
    let tray_icon = std::cell::RefCell::new(tray_icon);
    let popup_state = std::cell::RefCell::new(popup_state);
    let cursor_pos = std::cell::RefCell::new(egui::pos2(0.0, 0.0));

    // Run event loop
    event_loop.run(move |event, _event_loop, control_flow| {
        // Poll every 100ms for file changes and tray events
        *control_flow = ControlFlow::WaitUntil(
            std::time::Instant::now() + std::time::Duration::from_millis(100),
        );

        // Drain all tray icon events, only act on Click with button Up (release)
        while let Ok(event) = tray_icon::TrayIconEvent::receiver().try_recv() {
            // Only toggle popup on mouse button release
            if let tray_icon::TrayIconEvent::Click { button_state: tray_icon::MouseButtonState::Up, .. } = event {
                // Get tray icon position for popup placement
                if let Some(rect) = tray_icon.borrow().rect() {
                    let x = rect.position.x as i32;
                    let y = rect.position.y as i32 + rect.size.height as i32;

                    let mut state = popup_state.borrow_mut();

                    if state.visible {
                        state.hide();
                        window.set_visible(false);
                    } else {
                        // Position popup centered below tray icon
                        let popup_x = x - (POPUP_WIDTH as i32 / 2) + (rect.size.width as i32 / 2);
                        let popup_y = y + 4;
                        let popup_height = calculate_popup_height(&sessions.borrow());

                        window.set_outer_position(PhysicalPosition::new(popup_x, popup_y));
                        window.set_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64));
                        window.set_visible(true);

                        state.show();
                        window.request_redraw();
                    }
                }
            }
            // Ignore all other events (Move, Enter, Leave, Click with Down state)
        }

        // Handle window events
        match event {
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                // Check for file changes
                if let Some(ref mut w) = *watcher.borrow_mut() {
                    if let Some(new_sessions) = w.poll_changes() {
                        *sessions.borrow_mut() = new_sessions;

                        // Update window size if visible
                        if popup_state.borrow().visible {
                            let popup_height = calculate_popup_height(&sessions.borrow());
                            window.set_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64));
                            window.request_redraw();
                        }
                    }
                }
            }

            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }

            // Don't hide on focus loss - only hide on tray icon click or ESC
            Event::WindowEvent {
                event: WindowEvent::Focused(false),
                ..
            } => {
                // Do nothing - popup stays visible until user clicks tray icon again
            }

            Event::WindowEvent {
                event: WindowEvent::Resized(new_size),
                ..
            } => {
                if new_size.width > 0 && new_size.height > 0 {
                    // Update surface config with physical pixels
                    surface_config.width = new_size.width;
                    surface_config.height = new_size.height;
                    surface.configure(&device, &surface_config);

                    // Update scale factor (may change if window moves between displays)
                    current_scale_factor = window.scale_factor();
                    egui_ctx.set_pixels_per_point(current_scale_factor as f32);

                    // Update screen_rect with logical pixels
                    let logical_width = new_size.width as f32 / current_scale_factor as f32;
                    let logical_height = new_size.height as f32 / current_scale_factor as f32;
                    egui_input.screen_rect = Some(egui::Rect::from_min_size(
                        egui::Pos2::ZERO,
                        egui::vec2(logical_width, logical_height),
                    ));
                }
            }

            Event::WindowEvent {
                event: WindowEvent::ScaleFactorChanged { scale_factor: new_scale_factor, .. },
                ..
            } => {
                // Update scale factor for HiDPI changes
                current_scale_factor = new_scale_factor;
                egui_ctx.set_pixels_per_point(current_scale_factor as f32);

                // Reconfigure surface with new physical size
                let new_physical_size = window.inner_size();
                if new_physical_size.width > 0 && new_physical_size.height > 0 {
                    surface_config.width = new_physical_size.width;
                    surface_config.height = new_physical_size.height;
                    surface.configure(&device, &surface_config);

                    let logical_width = new_physical_size.width as f32 / current_scale_factor as f32;
                    let logical_height = new_physical_size.height as f32 / current_scale_factor as f32;
                    egui_input.screen_rect = Some(egui::Rect::from_min_size(
                        egui::Pos2::ZERO,
                        egui::vec2(logical_width, logical_height),
                    ));
                }
            }

            Event::WindowEvent {
                event: WindowEvent::CursorMoved { position, .. },
                ..
            } => {
                // Convert physical to logical pixels for egui
                let pos = egui::pos2(
                    position.x as f32 / current_scale_factor as f32,
                    position.y as f32 / current_scale_factor as f32,
                );
                *cursor_pos.borrow_mut() = pos;
                egui_input.events.push(egui::Event::PointerMoved(pos));
                // Request immediate redraw for responsive hover
                if popup_state.borrow().visible {
                    window.request_redraw();
                }
            }

            Event::WindowEvent {
                event: WindowEvent::MouseInput { state, button, .. },
                ..
            } => {
                let egui_button = match button {
                    tao::event::MouseButton::Left => egui::PointerButton::Primary,
                    tao::event::MouseButton::Right => egui::PointerButton::Secondary,
                    tao::event::MouseButton::Middle => egui::PointerButton::Middle,
                    _ => egui::PointerButton::Primary,
                };
                egui_input.events.push(egui::Event::PointerButton {
                    pos: *cursor_pos.borrow(),
                    button: egui_button,
                    pressed: state == tao::event::ElementState::Pressed,
                    modifiers: egui::Modifiers::default(),
                });
                // Request immediate redraw for responsive clicks
                if popup_state.borrow().visible {
                    window.request_redraw();
                }
            }

            Event::WindowEvent {
                event:
                    WindowEvent::KeyboardInput {
                        event:
                            tao::event::KeyEvent {
                                physical_key: tao::keyboard::KeyCode::Escape,
                                state: tao::event::ElementState::Pressed,
                                ..
                            },
                        ..
                    },
                ..
            } => {
                popup_state.borrow_mut().hide();
                window.set_visible(false);
            }

            Event::RedrawRequested(_) => {
                if !popup_state.borrow().visible {
                    return;
                }

                // Get surface texture
                let output = match surface.get_current_texture() {
                    Ok(output) => output,
                    Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                        surface.configure(&device, &surface_config);
                        return;
                    }
                    Err(e) => {
                        eprintln!("Surface error: {:?}", e);
                        return;
                    }
                };

                let view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());

                // Begin egui frame
                let input = egui_input.take();
                egui_ctx.begin_pass(input);

                // Render popup and get any clicked action
                let sessions = sessions.borrow();
                let clicked = render_popup(&egui_ctx, &sessions);

                // End egui frame
                let full_output = egui_ctx.end_pass();
                let paint_jobs = egui_ctx.tessellate(full_output.shapes, full_output.pixels_per_point);

                // Handle clicked actions
                if let Some(action) = clicked {
                    drop(sessions); // Release borrow before mutating popup_state

                    if action == QUIT_ACTION {
                        *control_flow = ControlFlow::Exit;
                        return;
                    } else {
                        // Find and focus the session
                        let sessions = sessions_dir.clone();
                        if let Ok(all_sessions) = Session::load_all(&sessions) {
                            if let Some(session) = all_sessions.iter().find(|s| s.session_id == action) {
                                if let Err(e) = focus_terminal(session, &config) {
                                    eprintln!("Failed to focus terminal: {}", e);
                                }
                            }
                        }

                        // Hide popup after clicking a session
                        popup_state.borrow_mut().hide();
                        window.set_visible(false);
                    }
                }

                // Update textures
                for (id, delta) in &full_output.textures_delta.set {
                    egui_renderer.update_texture(&device, &queue, *id, delta);
                }

                // Create command encoder
                let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("egui encoder"),
                });

                // Prepare screen descriptor
                let screen_descriptor = egui_wgpu::ScreenDescriptor {
                    size_in_pixels: [surface_config.width, surface_config.height],
                    pixels_per_point: window.scale_factor() as f32,
                };

                // Update buffers
                egui_renderer.update_buffers(
                    &device,
                    &queue,
                    &mut encoder,
                    &paint_jobs,
                    &screen_descriptor,
                );

                // Render
                {
                    let render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("egui render pass"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &view,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Clear(wgpu::Color {
                                    r: 0.0,
                                    g: 0.0,
                                    b: 0.0,
                                    a: 0.0,
                                }),
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                    });

                    // egui_wgpu::Renderer::render requires 'static lifetime on the render pass
                    // See: https://docs.rs/egui-wgpu/latest/egui_wgpu/struct.Renderer.html#method.render
                    let mut render_pass = render_pass.forget_lifetime();
                    egui_renderer.render(&mut render_pass, &paint_jobs, &screen_descriptor);
                }

                // Submit
                queue.submit(std::iter::once(encoder.finish()));
                output.present();

                // Free textures
                for id in &full_output.textures_delta.free {
                    egui_renderer.free_texture(id);
                }
            }

            _ => {}
        }
    });
}
