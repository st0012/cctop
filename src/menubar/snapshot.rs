//! Headless wgpu snapshot renderer for the cctop menubar popup.
//!
//! Renders the popup to a PNG file using offscreen wgpu rendering with the
//! exact same egui pipeline as the production menubar app. This produces
//! pixel-perfect output that matches what the user sees.

use crate::menubar::popup::{calculate_popup_height, render_popup, POPUP_WIDTH};
use crate::session::Session;
use anyhow::{Context, Result};
use std::path::Path;

/// Render the popup with given sessions to a PNG file.
/// Uses headless wgpu rendering (no window needed).
///
/// The output is rendered at 2x scale factor for Retina-quality output.
/// The resulting PNG dimensions are `(POPUP_WIDTH * 2) x (popup_height * 2)`.
pub fn render_popup_to_png(sessions: &[Session], output_path: &Path) -> Result<()> {
    let scale_factor: f32 = 2.0;
    let logical_width = POPUP_WIDTH;
    let logical_height = calculate_popup_height(sessions);

    let physical_width = (logical_width * scale_factor) as u32;
    let physical_height = (logical_height * scale_factor) as u32;

    let texture_format = wgpu::TextureFormat::Rgba8UnormSrgb;

    // 1. Create headless wgpu device (no surface needed)
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::all(),
        ..Default::default()
    });

    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::LowPower,
        compatible_surface: None,
        force_fallback_adapter: false,
    }))
    .context("Failed to find suitable GPU adapter for headless rendering")?;

    let (device, queue) = pollster::block_on(adapter.request_device(
        &wgpu::DeviceDescriptor {
            label: Some("cctop snapshot device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            memory_hints: wgpu::MemoryHints::default(),
        },
        None,
    ))
    .context("Failed to create GPU device for headless rendering")?;

    // 2. Create offscreen texture
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("snapshot texture"),
        size: wgpu::Extent3d {
            width: physical_width,
            height: physical_height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: texture_format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });

    let texture_view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    // 3. Set up egui context with dark theme
    let egui_ctx = egui::Context::default();
    egui_ctx.set_pixels_per_point(scale_factor);

    let mut style = (*egui_ctx.style()).clone();
    style.visuals = egui::Visuals::dark();
    egui_ctx.set_style(style);

    // 4. Create egui-wgpu renderer
    let mut egui_renderer = egui_wgpu::Renderer::new(&device, texture_format, None, 1, false);

    let raw_input = egui::RawInput {
        screen_rect: Some(egui::Rect::from_min_size(
            egui::Pos2::ZERO,
            egui::vec2(logical_width, logical_height),
        )),
        ..Default::default()
    };

    // 5. Warmup pass: egui needs one frame to initialize the font atlas texture.
    //    Without this, text won't render on the first (and only) real frame.
    {
        egui_ctx.begin_pass(raw_input.clone());
        let _ = render_popup(&egui_ctx, sessions);
        let warmup_output = egui_ctx.end_pass();

        // Process texture updates from warmup (loads font atlas)
        for (id, delta) in &warmup_output.textures_delta.set {
            egui_renderer.update_texture(&device, &queue, *id, delta);
        }
    }

    // 6. Real render pass
    egui_ctx.begin_pass(raw_input);
    let _ = render_popup(&egui_ctx, sessions);
    let full_output = egui_ctx.end_pass();

    // Tessellate
    let paint_jobs = egui_ctx.tessellate(full_output.shapes, full_output.pixels_per_point);

    // Update textures (fonts, etc.)
    for (id, delta) in &full_output.textures_delta.set {
        egui_renderer.update_texture(&device, &queue, *id, delta);
    }

    // 7. Render to offscreen texture
    let screen_descriptor = egui_wgpu::ScreenDescriptor {
        size_in_pixels: [physical_width, physical_height],
        pixels_per_point: scale_factor,
    };

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("snapshot encoder"),
    });

    egui_renderer.update_buffers(
        &device,
        &queue,
        &mut encoder,
        &paint_jobs,
        &screen_descriptor,
    );

    {
        let render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("snapshot render pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &texture_view,
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

    // 8. Copy texture to a mappable buffer
    // wgpu requires rows to be aligned to 256 bytes (COPY_BYTES_PER_ROW_ALIGNMENT)
    let bytes_per_pixel = 4u32; // RGBA8
    let unpadded_bytes_per_row = physical_width * bytes_per_pixel;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let padded_bytes_per_row = unpadded_bytes_per_row.div_ceil(align) * align;

    let buffer_size = (padded_bytes_per_row * physical_height) as u64;
    let output_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("snapshot output buffer"),
        size: buffer_size,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    encoder.copy_texture_to_buffer(
        wgpu::ImageCopyTexture {
            texture: &texture,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::ImageCopyBuffer {
            buffer: &output_buffer,
            layout: wgpu::ImageDataLayout {
                offset: 0,
                bytes_per_row: Some(padded_bytes_per_row),
                rows_per_image: Some(physical_height),
            },
        },
        wgpu::Extent3d {
            width: physical_width,
            height: physical_height,
            depth_or_array_layers: 1,
        },
    );

    queue.submit(std::iter::once(encoder.finish()));

    // 9. Read pixels from the buffer
    let buffer_slice = output_buffer.slice(..);
    let (sender, receiver) = std::sync::mpsc::channel();
    buffer_slice.map_async(wgpu::MapMode::Read, move |result| {
        sender.send(result).unwrap();
    });
    device.poll(wgpu::Maintain::Wait);
    receiver
        .recv()
        .context("Failed to receive buffer map result")?
        .context("Failed to map buffer")?;

    let data = buffer_slice.get_mapped_range();

    // Strip row padding to get contiguous pixel data
    let mut pixels =
        Vec::with_capacity((physical_width * physical_height * bytes_per_pixel) as usize);
    for row in 0..physical_height {
        let start = (row * padded_bytes_per_row) as usize;
        let end = start + (unpadded_bytes_per_row) as usize;
        pixels.extend_from_slice(&data[start..end]);
    }

    drop(data);
    output_buffer.unmap();

    // Free egui textures
    for id in &full_output.textures_delta.free {
        egui_renderer.free_texture(id);
    }

    // 10. Save as PNG using the image crate
    let img: image::ImageBuffer<image::Rgba<u8>, _> =
        image::ImageBuffer::from_raw(physical_width, physical_height, pixels)
            .context("Failed to create image buffer from pixel data")?;

    img.save(output_path)
        .with_context(|| format!("Failed to save PNG to {:?}", output_path))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Session, Status, TerminalInfo};
    use chrono::Utc;

    fn make_test_session(id: &str, status: Status, project: &str, branch: &str) -> Session {
        Session {
            session_id: id.to_string(),
            project_path: format!("/nonexistent/test/projects/{}", project),
            project_name: project.to_string(),
            branch: branch.to_string(),
            status,
            last_prompt: Some("Test prompt for this session".to_string()),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: TerminalInfo {
                program: "test".to_string(),
                session_id: None,
                tty: None,
            },
            pid: None,
            last_tool: None,
            last_tool_detail: None,
            notification_message: None,
            context_compacted: false,
        }
    }

    #[test]
    fn test_snapshot_typical_sessions() {
        let sessions = vec![
            {
                let mut s =
                    make_test_session("1", Status::WaitingPermission, "ruby/irb", "feature/repl");
                s.notification_message = Some("Allow Bash: bundle exec rake test".to_string());
                s
            },
            {
                let mut s = make_test_session("2", Status::Working, "cctop", "main");
                s.last_tool = Some("Bash".to_string());
                s.last_tool_detail = Some("cargo test".to_string());
                s
            },
            {
                let mut s = make_test_session("3", Status::WaitingInput, "rails", "fix/n+1");
                s.last_prompt = Some("Fix the N+1 query in UsersController#index".to_string());
                s
            },
            {
                let mut s = make_test_session("4", Status::Idle, "homebrew-core", "main");
                s.last_prompt = None;
                s
            },
        ];

        let output_path = std::path::PathBuf::from("/tmp/cctop_snapshot_typical.png");
        render_popup_to_png(&sessions, &output_path).expect("Failed to render snapshot");

        assert!(output_path.exists(), "Snapshot PNG was not created");
        let metadata = std::fs::metadata(&output_path).expect("Failed to read file metadata");
        assert!(
            metadata.len() > 1000,
            "Snapshot PNG is suspiciously small: {} bytes",
            metadata.len()
        );

        eprintln!("Typical sessions snapshot: {}", output_path.display());
    }

    #[test]
    fn test_snapshot_empty_sessions() {
        let sessions: Vec<Session> = vec![];

        let output_path = std::path::PathBuf::from("/tmp/cctop_snapshot_empty.png");
        render_popup_to_png(&sessions, &output_path).expect("Failed to render snapshot");

        assert!(output_path.exists(), "Snapshot PNG was not created");
        let metadata = std::fs::metadata(&output_path).expect("Failed to read file metadata");
        assert!(
            metadata.len() > 500,
            "Snapshot PNG is suspiciously small: {} bytes",
            metadata.len()
        );

        eprintln!("Empty sessions snapshot: {}", output_path.display());
    }
}
