//! GPU renderer for the menubar popup using wgpu and egui.

use anyhow::{Context, Result};
use objc2::msg_send;
use objc2::runtime::AnyObject;
use std::sync::Arc;
use tao::platform::macos::WindowExtMacOS;
use tao::window::Window;

/// Encapsulates wgpu device, surface, and egui renderer.
/// Handles transparent window rendering on macOS.
pub struct Renderer {
    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
    egui_ctx: egui::Context,
    egui_renderer: egui_wgpu::Renderer,
    scale_factor: f64,
    /// Stored ns_view pointer for layer opacity management.
    ns_view: *mut AnyObject,
}

// Safety: ns_view pointer is only used on the main thread for objc calls
unsafe impl Send for Renderer {}

impl Renderer {
    /// Create a new renderer for the given window.
    pub fn new(window: &Window) -> Result<Self> {
        // Store ns_view pointer for later use
        let ns_view = window.ns_view() as *mut AnyObject;

        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });

        // Create surface from window
        let surface = unsafe {
            instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::from_window(window)?)
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

        // Configure surface
        let physical_size = window.inner_size();
        let scale_factor = window.scale_factor();

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .iter()
            .find(|f| f.is_srgb())
            .copied()
            .unwrap_or(surface_caps.formats[0]);

        // Use PreMultiplied alpha for proper window transparency
        let alpha_mode = if surface_caps
            .alpha_modes
            .contains(&wgpu::CompositeAlphaMode::PreMultiplied)
        {
            wgpu::CompositeAlphaMode::PreMultiplied
        } else {
            wgpu::CompositeAlphaMode::Auto
        };

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: physical_size.width.max(1),
            height: physical_size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode,
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };

        // Configure surface and set layer opacity
        surface.configure(&device, &surface_config);
        Self::set_layer_opaque_raw(ns_view, false);

        // Initialize egui
        let egui_ctx = egui::Context::default();
        egui_ctx.set_pixels_per_point(scale_factor as f32);

        // Configure dark theme
        let mut style = (*egui_ctx.style()).clone();
        style.visuals = egui::Visuals::dark();
        egui_ctx.set_style(style);

        // Create egui-wgpu renderer
        let egui_renderer = egui_wgpu::Renderer::new(&device, surface_format, None, 1, false);

        Ok(Self {
            device,
            queue,
            surface,
            surface_config,
            egui_ctx,
            egui_renderer,
            scale_factor,
            ns_view,
        })
    }

    /// Internal: configure surface and re-apply layer opacity.
    /// This must be called instead of surface.configure() directly.
    fn configure_surface(&self) {
        self.surface.configure(&self.device, &self.surface_config);
        Self::set_layer_opaque_raw(self.ns_view, false);
    }

    /// Set the CAMetalLayer opacity for window transparency.
    fn set_layer_opaque_raw(ns_view: *mut AnyObject, opaque: bool) {
        unsafe {
            let layer: *mut AnyObject = msg_send![ns_view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setOpaque: opaque];
            }
        }
    }

    /// Get the egui context for input handling.
    pub fn egui_ctx(&self) -> &egui::Context {
        &self.egui_ctx
    }

    /// Get the current scale factor.
    pub fn scale_factor(&self) -> f64 {
        self.scale_factor
    }

    /// Resize the surface when the window changes size.
    /// Automatically re-applies layer opacity for transparency.
    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.surface_config.width = width;
            self.surface_config.height = height;
            self.configure_surface();
        }
    }

    /// Update the scale factor (e.g., when moving between displays).
    pub fn set_scale_factor(&mut self, scale_factor: f64) {
        self.scale_factor = scale_factor;
        self.egui_ctx.set_pixels_per_point(scale_factor as f32);
    }

    /// Render a frame using the provided draw function.
    /// Returns (result, repaint_after) where repaint_after is the duration
    /// egui requests before the next repaint (Duration::MAX if no repaint needed).
    pub fn render<T, F>(
        &mut self,
        input: egui::RawInput,
        draw_fn: F,
    ) -> Result<(T, std::time::Duration)>
    where
        F: FnOnce(&egui::Context) -> T,
    {
        // Get surface texture
        let output = match self.surface.get_current_texture() {
            Ok(output) => output,
            Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                self.configure_surface();
                return Err(anyhow::anyhow!("Surface lost, reconfigured"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!("Surface error: {:?}", e));
            }
        };

        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        // Begin egui frame
        self.egui_ctx.begin_pass(input);

        // Call the draw function
        let result = draw_fn(&self.egui_ctx);

        // End egui frame
        let full_output = self.egui_ctx.end_pass();

        // Extract the repaint delay from the root viewport output.
        // This tells us when egui wants the next repaint (for animations).
        let repaint_after = full_output
            .viewport_output
            .get(&egui::ViewportId::ROOT)
            .map(|vo| vo.repaint_delay)
            .unwrap_or(std::time::Duration::MAX);

        let paint_jobs = self
            .egui_ctx
            .tessellate(full_output.shapes, full_output.pixels_per_point);

        // Update textures
        for (id, delta) in &full_output.textures_delta.set {
            self.egui_renderer
                .update_texture(&self.device, &self.queue, *id, delta);
        }

        // Create command encoder
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("egui encoder"),
            });

        // Prepare screen descriptor
        let screen_descriptor = egui_wgpu::ScreenDescriptor {
            size_in_pixels: [self.surface_config.width, self.surface_config.height],
            pixels_per_point: self.scale_factor as f32,
        };

        // Update buffers
        self.egui_renderer.update_buffers(
            &self.device,
            &self.queue,
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
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            let mut render_pass = render_pass.forget_lifetime();
            self.egui_renderer
                .render(&mut render_pass, &paint_jobs, &screen_descriptor);
        }

        // Submit
        self.queue.submit(std::iter::once(encoder.finish()));
        output.present();

        // Free textures
        for id in &full_output.textures_delta.free {
            self.egui_renderer.free_texture(id);
        }

        Ok((result, repaint_after))
    }

    /// Perform a warmup render to initialize GPU resources.
    /// This prevents delay on first click.
    pub fn warmup<F>(&mut self, draw_fn: F) -> Result<()>
    where
        F: FnOnce(&egui::Context),
    {
        let input = egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(
                    self.surface_config.width as f32 / self.scale_factor as f32,
                    self.surface_config.height as f32 / self.scale_factor as f32,
                ),
            )),
            ..Default::default()
        };
        let _ = self.render(input, draw_fn)?;
        Ok(())
    }

    /// Create a RawInput with the current screen rect.
    pub fn create_input(&self) -> egui::RawInput {
        egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(
                    self.surface_config.width as f32 / self.scale_factor as f32,
                    self.surface_config.height as f32 / self.scale_factor as f32,
                ),
            )),
            ..Default::default()
        }
    }
}
