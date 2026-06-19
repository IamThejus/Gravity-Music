---
name: Gravity Music
colors:
  surface: '#141313'
  surface-dim: '#141313'
  surface-bright: '#3a3939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353434'
  on-surface: '#e5e2e1'
  on-surface-variant: '#c4c7c8'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#8e9192'
  outline-variant: '#444748'
  surface-tint: '#c6c6c7'
  primary: '#ffffff'
  on-primary: '#2f3131'
  primary-container: '#e2e2e2'
  on-primary-container: '#636565'
  inverse-primary: '#5d5f5f'
  secondary: '#c9c6c5'
  on-secondary: '#313030'
  secondary-container: '#4a4949'
  on-secondary-container: '#bab8b7'
  tertiary: '#ffffff'
  on-tertiary: '#313030'
  tertiary-container: '#e5e2e1'
  on-tertiary-container: '#656464'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e2e2e2'
  primary-fixed-dim: '#c6c6c7'
  on-primary-fixed: '#1a1c1c'
  on-primary-fixed-variant: '#454747'
  secondary-fixed: '#e5e2e1'
  secondary-fixed-dim: '#c9c6c5'
  on-secondary-fixed: '#1c1b1b'
  on-secondary-fixed-variant: '#474646'
  tertiary-fixed: '#e5e2e1'
  tertiary-fixed-dim: '#c8c6c5'
  on-tertiary-fixed: '#1c1b1b'
  on-tertiary-fixed-variant: '#474746'
  background: '#141313'
  on-background: '#e5e2e1'
  surface-variant: '#353434'
typography:
  display-hero:
    fontFamily: Inter
    fontSize: 40px
    fontWeight: '700'
    lineHeight: 48px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 34px
  title-md:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 24px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-caps:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  screen-margin: 1.25rem
  gutter: 1rem
  stack-sm: 0.5rem
  stack-md: 1.5rem
  stack-lg: 2.5rem
---

## Brand & Style

The design system is engineered to evoke a sense of deep immersion and premium weightlessness. It is a "Cinematic Dark" aesthetic that prioritizes the artist's content above the interface itself. The brand personality is sophisticated, atmospheric, and obsidian—designed for audiophiles who view music as an experiential journey rather than a background utility.

The visual style leverages **Glassmorphism** and **Atmospheric Layering**. By utilizing "suspended" layouts where no element touches the physical edge of the display, the interface feels like a high-end physical device made of light and glass. It targets an audience that appreciates the polish of flagship hardware and the richness of high-fidelity audio services like Tidal and Apple Music.

## Colors

The palette is anchored in an absolute obsidian black (`#000000`) to maximize the contrast of OLED displays and allow dynamic ambient glows to "bleed" naturally into the environment. 

- **Primary Canvas:** Absolute Black for the base layer.
- **Secondary Surfaces:** Used for cards and inset containers to provide subtle structural definition.
- **Content Hierarchy:** High-contrast Pure White is reserved for primary titles. Secondary information uses 60% opacity white, and tertiary metadata/labels use 40% opacity.
- **Dynamic Accent:** While white is the UI primary, the functional accent color is dynamic, pulled programmatically from the current track's album artwork to create a custom-tailored environment for every song.

## Typography

This design system utilizes **Inter** as its primary typeface to ensure maximum legibility and a contemporary, "Android-plus" feel. The type system relies on tight tracking and significant weight variance to create a clear information hierarchy.

- **Hero & Headlines:** Use Bold weights with negative letter-spacing for a high-end editorial look.
- **Navigation & Metadata:** Use Semibold for card titles and "Label-Caps" for categories (e.g., "PLAYLIST" or "NEW RELEASE") to provide clear visual anchors.
- **Accessibility:** For mobile devices, font sizes scale down slightly to maintain the "suspended" layout philosophy without crowding the screen.

## Layout & Spacing

The layout philosophy is defined by **Suspended Containment**. No container, button, or navigation bar touches the edge of the device frame.

- **Floating Margins:** A mandatory 20px (1.25rem) safe-area margin exists around the entire application. 
- **The Floating Stack:** Content is organized in a vertical stack of rounded containers. 
- **Navigation:** The bottom navigation and mini-player are treated as distinct glass layers floating above the content stack, rather than being pinned to the bottom.
- **Grid:** A 4-column fluid grid for mobile, expanding to 8 or 12 for larger tablet displays, always maintaining the external "air" between the content and the screen edge.

## Elevation & Depth

Visual hierarchy is communicated through **Z-axis Depth** and **Backdrop Blurs** rather than traditional drop shadows.

1.  **Base Layer (Z0):** Pure black background with dynamic radial gradients (20-40% opacity) reflecting the current music.
2.  **Content Layer (Z1):** Secondary surface cards for albums and lists.
3.  **Glass Layer (Z2):** Floating elements like the Mini-player, Search Bar, and Bottom Nav. These use a 30px backdrop blur and a thin 1px inner border (`rgba(255, 255, 255, 0.12)`) to simulate the edge of a glass pane.
4.  **Shadows:** Shadows are used sparingly only on Z2 elements to lift them off the content. Use a highly diffused, ultra-low opacity shadow: `0px 8px 40px rgba(0,0,0,0.25)`.

## Shapes

The shape language is consistently **Rounded**, reflecting the high-end industrial design of modern flagship smartphones. 

- **Standard Containers:** Use `rounded-lg` (1rem) for album art and content cards.
- **Floating Controls:** Floating navigation bars and the mini-player use `rounded-xl` (1.5rem) or full pill-shaping to emphasize their "object-like" quality.
- **Consistency:** Avoid sharp corners entirely to maintain the soft, atmospheric aesthetic.

## Components

### Buttons
Primary actions use a "Glass-Fill" style—a white container with 10% opacity and a high-blur background. For secondary actions, use text-only with a semibold weight. "Play" buttons should be treated as circular floating objects.

### Mini-Player
A persistent floating component. It must feature the 30px blur and the 12% white border. The track progress should be represented by a 2px thin line at the very bottom of the floating glass container.

### Cards
Album and Playlist cards should not have visible borders. They rely on the secondary surface color (`#0B0B0B`) and subtle depth to separate from the background. The art should have a slight "inner glow" to prevent it from disappearing into the black background.

### Input Fields
Search fields should mirror the glassmorphic style of the navigation. Use a magnifying glass icon at 40% opacity as the prefix.

### Interactive States
Upon pressing any glass element, the opacity of the white fill should increase from 8% to 16% to provide tactile feedback without changing the color palette.