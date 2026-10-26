use fframes::{
    AnimateRuntimeInput, AudioMap, AudioTimestamp::*, AudioTrack, Color, Duration,
    FFramesContext, FontQuery, Frame, Overlap, Scene, Scenes, Svgr, Transform, Video,
    animation::{AnimationRuntime, Easing}, include_media_dir,
};
use std::sync::LazyLock;

include_media_dir!(pub struct MacscreenshotPromoMedia, "media");
mod timing;

pub const WIDTH: usize = 1920;
pub const HEIGHT: usize = 1080;
const FONT: &str = "DM Sans";
const INK: &str = "#F6F3FF";
const MUTED: &str = "#B5AEC8";
const ACCENT: &str = "#AE8FFF";

static ENTER: LazyLock<AnimationRuntime> =
    LazyLock::new(|| AnimationRuntime::new(0.65, &Easing::CubicBezier(0.16, 1.0, 0.3, 1.0)));
static FADE: LazyLock<AnimationRuntime> =
    LazyLock::new(|| AnimationRuntime::new(0.32, &Easing::EaseInOut));

#[derive(Debug)]
pub struct MacscreenshotPromoVideo {
    shots: Vec<Shot>,
}

impl MacscreenshotPromoVideo {
    pub fn new() -> Self {
        Self {
            shots: timing::CUES.iter().enumerate().map(|(index, &(name, duration, audio))| Shot {
                index, name, duration, audio,
                camera: AnimationRuntime::new(duration + 0.32, &Easing::EaseInOut),
            }).collect(),
        }
    }
}

impl Default for MacscreenshotPromoVideo {
    fn default() -> Self { Self::new() }
}

impl Video for MacscreenshotPromoVideo {
    const FPS: usize = 60;
    const WIDTH: usize = WIDTH;
    const HEIGHT: usize = HEIGHT;
    const BACKGROUND_COLOR: Color = Color::BLACK;
    fn duration(&self) -> Duration<'_> { Duration::Auto }
    fn audio(&self) -> AudioMap<'_> { AudioMap::none() }
    fn define_scenes(&self) -> Scenes<'_> {
        Scenes::from(self.shots.iter().map(|s| s as &dyn Scene).collect::<Vec<_>>())
    }
    fn render_frame<'a>(&'a self, frame: Frame, ctx: &FFramesContext<'a, '_>) -> Svgr<'a> {
        fframes::svgr!(
            <svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
                <defs>
                    <radialGradient id="ambient" cx="78%" cy="35%" r="82%">
                        <stop offset="0" stop-color="#292042"/>
                        <stop offset="0.6" stop-color="#120F20"/>
                        <stop offset="1" stop-color="#090811"/>
                    </radialGradient>
                    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
                        <stop offset="0" stop-color="#7F63BB" stop-opacity="0.55"/>
                        <stop offset="1" stop-color="#393044" stop-opacity="0.16"/>
                    </linearGradient>
                    <linearGradient id="title-glow" x1="0" y1="0" x2="1" y2="0">
                        <stop offset="0" stop-color="#EDE3FF"/>
                        <stop offset="1" stop-color="#9D77FF"/>
                    </linearGradient>
                </defs>
                <rect width="1920" height="1080" fill="url(#ambient)"/>
                {ctx.render_scenes(&frame)}
                <g font-family={FONT} font-weight="500">
                    <text x="160" y="91" font-size="29" fill={INK}>"MacScreenShot"</text>
                    <text x="1760" y="91" text-anchor="end" font-size="28" fill={MUTED}>"CAPTURE. CREATE. KEEP."</text>
                </g>
            </svg>
        )
    }
}

#[derive(Debug)]
struct Shot {
    index: usize,
    name: &'static str,
    duration: f32,
    audio: &'static str,
    camera: AnimationRuntime,
}

fn enter(frame: &Frame, start: f32) -> f32 {
    frame.animate_runtime(AnimateRuntimeInput {
        on_second: start, from: 0.0, to: 1.0, animation_runtime: &ENTER,
    })
}

fn title<'a>(frame: &mut Frame, ctx: &FFramesContext<'a, '_>, text: &'a str,
             x: f32, y: f32, preferred: usize, width: usize, delay: f32, fill: &'a str) -> Svgr<'a> {
    let mut size = preferred;
    while size > 28 && frame.text_width(ctx, FontQuery {
        family: FONT, size, weight: 500, ..Default::default()
    }, text).unwrap_or(width) > width { size -= 2; }
    let p = enter(frame, delay);
    fframes::svgr!(
        <g opacity={p} transform={Transform::translate(0., 30. * (1. - p))}>
            <text x={x} y={y} font-family={FONT} font-weight="500"
                font-size={size} letter-spacing="-2" fill={fill}>{text}</text>
        </g>
    )
}

fn label<'a>(text: &'a str, x: f32, y: f32) -> Svgr<'a> {
    fframes::svgr!(<text x={x} y={y} font-family={FONT} font-size="28"
        font-weight="500" letter-spacing="3" fill={ACCENT}>{text}</text>)
}

fn raw_image<'a>(ctx: &FFramesContext<'a, '_>, key: &str,
                 x: f32, y: f32, w: f32, h: f32) -> Svgr<'a> {
    let Some(image) = ctx.get_image(key) else { return Svgr::empty(); };
    fframes::svgr!(<image href={image.href()} x={x} y={y} width={w} height={h}
        preserveAspectRatio="xMidYMid meet"/>)
}

fn picture<'a>(ctx: &FFramesContext<'a, '_>, key: &str, id: &'a str,
               x: f32, y: f32, w: f32, h: f32, zoom: f32, drift: f32) -> Svgr<'a> {
    let clip = format!("url(#{id})");
    let transform = format!("translate({} {}) scale({zoom})",
                            (x + w / 2.) * (1. - zoom) + drift, (y + h / 2.) * (1. - zoom));
    fframes::svgr!(<g>
        <defs><clipPath id={id}><rect x={x} y={y} width={w} height={h} rx="22"/></clipPath></defs>
        <rect x={x - 8.} y={y + 14.} width={w + 16.} height={h + 16.} rx="30" fill="#050409" opacity="0.52"/>
        <g clip-path={clip}>
            <rect x={x} y={y} width={w} height={h} fill="#17151D"/>
            <g transform={transform}>{raw_image(ctx, key, x, y, w, h)}</g>
        </g>
        <rect x={x} y={y} width={w} height={h} rx="22" fill="none" stroke="url(#rim)" stroke-width="2"/>
    </g>)
}

fn keys<'a>() -> Svgr<'a> {
    fframes::svgr!(<g transform="translate(1368 153)" stroke="#E5DBFA" stroke-width="3" fill="none">
        <rect width="112" height="84" rx="18" fill="#211A32" stroke="#51416E"/>
        <path d="M38 31V22C38 10 20 10 20 22C20 34 38 31 38 31H66V61H38ZM66 31V22C66 10 84 10 84 22C84 34 66 31 66 31M38 61V70C38 82 20 82 20 70C20 58 38 61 38 61M66 61V70C66 82 84 82 84 70C84 58 66 61 66 61"
              transform="translate(3 -4) scale(0.94)"/>
        <g transform="translate(132 0)">
            <rect width="112" height="84" rx="18" fill="#211A32" stroke="#51416E"/>
            <path d="M55 20L81 46H67V67H43V46H29Z"/>
        </g>
        <g transform="translate(264 0)">
            <rect width="112" height="84" rx="18" fill="#211A32" stroke="#51416E"/>
            <text x="56" y="58" text-anchor="middle" font-family="DM Sans" font-weight="500"
                  font-size="48" stroke="none" fill="#F6F3FF">"4"</text>
        </g>
    </g>)
}

impl Scene for Shot {
    fn name(&self) -> &'static str { self.name }
    fn duration(&self) -> Duration<'_> { Duration::Seconds(self.duration) }
    fn overlap(&self) -> Overlap {
        if self.index == 0 { Overlap::None } else { Overlap::Previous(0.32) }
    }
    fn audio(&self) -> AudioMap<'_> {
        AudioMap::from([AudioTrack::new(self.audio, Second(0.62)..Eof).voice()])
    }
    fn render_frame<'a>(&'a self, mut frame: Frame, ctx: &FFramesContext<'a, '_>) -> Svgr<'a> {
        let p = frame.animate_runtime(AnimateRuntimeInput {
            on_second: 0., from: 0., to: 1., animation_runtime: &self.camera,
        });
        let opacity = if self.index == 0 { 1.0 } else {
            frame.animate_runtime(AnimateRuntimeInput {
                on_second: 0., from: 0., to: 1., animation_runtime: &FADE,
            })
        };
        let content = match self.index {
            0 => fframes::svgr!(<g>
                {label("A LITTLE APP. A LOT OF POSSIBILITY.", 160., 245.)}
                <text x="151" y="425" font-family={FONT} font-weight="500" font-size="134"
                      letter-spacing="-6" fill={INK}>"Your screen."</text>
                {title(&mut frame, ctx, "Beautifully", 153., 578., 134, 940, 0.12, "url(#title-glow)")}
                {title(&mut frame, ctx, "told.", 153., 731., 134, 900, 0.22, "url(#title-glow)")}
                <g transform={format!("translate(0 {})", -18. * p)}>
                    {raw_image(ctx, "app-icon.png", 1265., 340., 390., 390.)}
                </g>
                <text x="160" y="851" font-family={FONT} font-weight="500" font-size="35"
                      fill={MUTED}>"Screenshots + screen recordings. Made for Mac."</text>
            </g>),
            1 => fframes::svgr!(<g>
                {title(&mut frame, ctx, "Catch the moment.", 160., 222., 78, 1110, 0.08, INK)}
                {keys()}
                {picture(ctx, "selector.png", "selector-clip", 390., 283., 1155., 649.7, 1. + 0.055 * p, -12. * p)}
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>
                    "Freeze your screen. Pick a window. Or select an area."
                </text>
            </g>),
            2 => fframes::svgr!(<g>
                {label("MAKE YOUR POINT", 160., 237.)}
                {title(&mut frame, ctx, "Nine tools.", 156., 364., 96, 655, 0.06, INK)}
                {title(&mut frame, ctx, "Zero regrets.", 156., 483., 96, 655, 0.15, "url(#title-glow)")}
                <text x="160" y="606" font-family={FONT} font-size="37" font-weight="500" fill={MUTED}>"Every edit stays editable."</text>
                {picture(ctx, "editor.png", "editor-clip", 860., 235., 890., 603.4, 1. + 0.025 * p, 0.)}
                <g opacity={enter(&frame, 1.3)}>
                    {picture(ctx, "editor-tools.png", "toolbar-clip", 185., 735., 598., 70., 1., 0.)}
                </g>
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Annotate. Highlight. Redact. Keep the original."</text>
            </g>),
            3 => fframes::svgr!(<g>
                {title(&mut frame, ctx, "From screenshot to showpiece.", 160., 222., 78, 1600, 0.08, INK)}
                {picture(ctx, "beauty-canvas.png", "beautify-clip", 456., 284., 1010., 659.5, 1.035 - 0.03 * p, 0.)}
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Gradient backdrops. Rounded corners. Soft shadows."</text>
            </g>),
            4 => fframes::svgr!(<g>
                {label("AND WHEN A STILL ISN’T ENOUGH", 160., 241.)}
                {title(&mut frame, ctx, "Let it roll.", 155., 390., 126, 1500, 0.08, INK)}
                <g opacity={enter(&frame, 0.25)}>
                    <rect x="160" y="479" width="1600" height="327" rx="34" fill="#15101F" stroke="url(#rim)" stroke-width="2"/>
                    <g transform="translate(278 550)" stroke="#B597EF" stroke-width="5" fill="none">
                        <rect width="180" height="111" rx="10"/><path d="M90 111V142M46 142H134"/>
                    </g>
                    <text x="368" y="750" text-anchor="middle" font-family={FONT} font-size="34" fill={INK}>"Display"</text>
                    <g transform="translate(705 550)" stroke="#B597EF" stroke-width="5" fill="none">
                        <rect width="180" height="134" rx="10"/><path d="M0 30H180"/>
                        <circle cx="18" cy="15" r="3" fill="#B597EF"/>
                    </g>
                    <text x="795" y="750" text-anchor="middle" font-family={FONT} font-size="34" fill={INK}>"Window"</text>
                    <g transform="translate(1124 550)" stroke="#B597EF" stroke-width="5" fill="none">
                        <rect width="180" height="134" rx="10" stroke-dasharray="12 9"/>
                    </g>
                    <text x="1214" y="750" text-anchor="middle" font-family={FONT} font-size="34" fill={INK}>"Area"</text>
                    {raw_image(ctx, "hud.png", 1450., 588., 258., 84.)}
                </g>
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Choose exactly what you want to record."</text>
            </g>),
            5 => fframes::svgr!(<g>
                {title(&mut frame, ctx, "A little studio. A big difference.", 160., 222., 76, 1600, 0.08, INK)}
                {picture(ctx, "studio.png", "studio-clip", 427., 278., 1070., 673.0, 1. + 0.045 * p, -8. * p)}
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Optional studio editor  /  Auto-zoom + a smooth synthetic cursor"</text>
            </g>),
            6 => fframes::svgr!(<g>
                {label("THE FINISHING TOUCH", 160., 239.)}
                {title(&mut frame, ctx, "Make it", 155., 377., 109, 640, 0.06, INK)}
                {title(&mut frame, ctx, "move you.", 155., 500., 109, 640, 0.15, "url(#title-glow)")}
                <text x="151" y="733" font-family={FONT} font-weight="500" font-size="168" letter-spacing="-6" fill={INK}>"60"</text>
                <text x="370" y="725" font-family={FONT} font-weight="500" font-size="44" fill={ACCENT}>"fps export"</text>
                {picture(ctx, "studio-canvas.png", "export-clip", 823., 268., 923., 628.6, 1.045 - 0.035 * p, 0.)}
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Beautiful backdrops. Smooth MP4s. Your raw take, untouched."</text>
            </g>),
            7 => fframes::svgr!(<g>
                {label("ALWAYS WITHIN REACH", 160., 239.)}
                {title(&mut frame, ctx, "Everything, right here.", 155., 373., 102, 1600, 0.08, INK)}
                {picture(ctx, "notch.png", "history-clip", 281., 427., 1358., 520.1, 1. + 0.02 * p, 0.)}
                <text x="160" y="1010" font-family={FONT} font-size="31" font-weight="500" fill={MUTED}>"Screenshots + recordings. In your library and notch history."</text>
            </g>),
            8 => fframes::svgr!(<g>
                {label("PRIVATE BY DESIGN", 160., 239.)}
                {title(&mut frame, ctx, "Your Mac.", 155., 396., 126, 1120, 0.07, INK)}
                {title(&mut frame, ctx, "Your business.", 155., 542., 126, 1120, 0.16, "url(#title-glow)")}
                <g transform="translate(1420 333)" stroke="#B699F2" stroke-width="10" fill="none">
                    <path d="M0 110V63C0 -39 144 -39 144 63V110"/>
                    <rect x="-30" y="100" width="204" height="177" rx="32" fill="#211832"/>
                    <circle cx="72" cy="169" r="13" fill="#D2BFFF" stroke="none"/>
                    <path d="M72 181V220" stroke-linecap="round"/>
                </g>
                <g opacity={enter(&frame, 0.38)}>
                    <path d="M160 679H1760" stroke="#40334F" stroke-width="2"/>
                    <text x="160" y="760" font-family={FONT} font-size="39" fill={INK}>"One permission."</text>
                    <text x="738" y="760" font-family={FONT} font-size="39" fill={INK}>"No account."</text>
                    <text x="1270" y="760" font-family={FONT} font-size="39" fill={INK}>"No telemetry."</text>
                </g>
                <text x="160" y="862" font-family={FONT} font-size="37" fill={MUTED}>"Your captures never leave your Mac."</text>
                <text x="160" y="1010" font-family={FONT} font-size="28" fill={MUTED}>"Only Screen Recording permission. All capture processing on-device."</text>
            </g>),
            _ => fframes::svgr!(<g>
                {raw_image(ctx, "app-icon.png", 159., 240., 162., 162.)}
                {title(&mut frame, ctx, "Free. Open source. Yours.", 153., 566., 110, 1610, 0.09, INK)}
                <g opacity={enter(&frame, 0.3)}>
                    <rect x="160" y="651" width="1600" height="129" rx="26" fill="#281C40" stroke="#61458E" stroke-width="2"/>
                    <text x="206" y="731" font-family={FONT} font-weight="500" font-size="49" fill="#E8DBFF">
                        "github.com/winterzxzz/winter_shot"
                    </text>
                    <path d="M1630 716H1685M1665 695L1686 716L1665 737" stroke="#DCC6FF" stroke-width="5" fill="none"/>
                </g>
                <text x="160" y="865" font-family={FONT} font-size="34" fill={MUTED}>"Download MacScreenShot. Make something worth sharing."</text>
                <text x="160" y="1010" font-family={FONT} font-size="28" fill={MUTED}>"MIT LICENSED  /  macOS 14+  /  APPLE SILICON"</text>
            </g>),
        };
        fframes::svgr!(<g opacity={opacity}>
            <rect width="1920" height="1080" fill="url(#ambient)"/>
            {content}
            <g font-family={FONT} font-size="28" fill={MUTED}>
                <text x="1760" y="1010" text-anchor="end">{format!("{:02} / 10", self.index + 1)}</text>
            </g>
        </g>)
    }
}
