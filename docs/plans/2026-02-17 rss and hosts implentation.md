# BitFlip.show RSS Feed & Hosts Collection Implementation

Date: February 17, 2026

## Summary
This document covers the implementation of the podcast RSS feed using the official `@astrojs/rss` package and the addition of a content collection for hosts with individual host pages.

## RSS Feed Implementation

### Package Addition
Added `@astrojs/rss` to dependencies:
```json
"dependencies": {
  "@astrojs/rss": "^4.0.9",
  "astro": "^5.17.1",
  "yaml": "^2.8.2"
}
```

### Feed Structure
**Location**: `src/pages/rss.xml.js`

**Key Features**:
- Uses official Astro RSS package per documentation
- Includes iTunes podcast namespace tags
- Generates absolute URLs for cover images
- Sorts episodes by date (newest first)
- Includes audio enclosures with proper MIME types

**Channel Metadata**:
- Title: BitFlip.show
- Language: en-us
- Type: episodic
- Category: Technology
- Show artwork: `/images/cover.png` (must be 1400×1400 to 3000×3000 pixels, square)

**Per-Episode Metadata**:
- Episode number and title
- Duration (HH:MM:SS format)
- Explicit flag
- Cover image (falls back to show artwork if not specified)
- Audio enclosure (URL, size in bytes, type)

### Content Schema Updates
**Location**: `src/content/config.ts`

Made `coverImage` optional with default fallback:
```typescript
coverImage: z.string().optional().default("/images/cover.png")
```

This allows episodes to omit `coverImage` in frontmatter and automatically use the show artwork.

### Technical Notes
- RSS feed is generated fresh on every request (stateless)
- GUID is based on episode number, so changing episode numbers creates new entries
- Title, description, and metadata can be freely edited without creating duplicates
- Image requirements: square, 1400-3000px, served with proper MIME type
- Podcast directories cache artwork aggressively (24-48 hours for updates)

## Hosts Content Collection

### Schema Definition
**Location**: `src/content/config.ts`

Added `hosts` collection:
```typescript
const hosts = defineCollection({
  type: "content",
  schema: z.object({
    name: z.string(),
    role: z.string().optional(),
    avatar: z.string().optional(),
    social: z.object({
      github: z.string().optional(),
      twitter: z.string().optional(),
      mastodon: z.string().optional(),
      website: z.string().optional(),
      linkedin: z.string().optional(),
      youtube: z.string().optional(),
    }).optional(),
    order: z.number().optional().default(999),
  }),
});
```

### Content Structure
**Location**: `src/content/hosts/`

Each host gets a markdown file (e.g., `alex.md`, `adam.md`):
```markdown
---
name: "Alex Kretzschmar"
role: "Co-host"
avatar: "/images/hosts/alex.jpg"
order: 1
social:
  github: "https://github.com/ironicbadger"
  twitter: "https://twitter.com/ironicbadger"
  youtube: "https://youtube.com/@ironicbadger"
---

Bio content in markdown...
```

### Pages

#### Hosts Index Page
**Location**: `src/pages/hosts.astro`

**Features**:
- Grid layout: 2 hosts per row (1 on mobile)
- Displays avatar, name, role, bio excerpt
- Social media icons (Website, GitHub, Twitter, Mastodon, YouTube, LinkedIn)
- Sorted by `order` field (ascending)

#### Individual Host Pages
**Location**: `src/pages/hosts/[slug].astro`

**Features**:
- Larger avatar (160px vs 120px)
- Full markdown bio rendering
- Social media links
- URL pattern: `/hosts/alex`, `/hosts/adam`, etc.

### Social Networks Supported
- Website (fa-globe)
- GitHub (fa-brands fa-github)
- Twitter (fa-brands fa-twitter)
- Mastodon (fa-brands fa-mastodon)
- YouTube (fa-brands fa-youtube)
- LinkedIn (fa-brands fa-linkedin)

## Episodes Page

### New Dedicated Page
**Location**: `src/pages/episodes.astro`

**Features**:
- Grid layout: 2 episodes per row (1 on mobile)
- Displays: episode number, title, date, duration, tags
- Sorted by date (newest first)
- Card hover effects
- Links to individual episode detail pages

### Navigation Update
**Location**: `src/layouts/Base.astro`

Changed navigation link from `/` to `/episodes`:
```html
<a href="/episodes">Episodes</a>
```

### Routing Structure
- `/episodes` → Episodes list page
- `/[episode]` → Individual episode detail (e.g., `/101`, `/102`)
- Astro prioritizes static routes over dynamic routes, so no conflicts

## Mobile Improvements

### Header Layout Fix
**Location**: `src/styles/theme.css`

**Issue**: On mobile, navigation links overlaid the logo and tagline.

**Solution**:
- At 768px: Header switches to vertical stacking
- At 480px: Further size reductions for logo and fonts
- Navigation appears below brand instead of beside it

## File Locations Summary

### New Files
- `src/pages/episodes.astro` - Episodes list page
- `src/pages/hosts/[slug].astro` - Individual host pages
- `src/content/hosts/*.md` - Host content files

### Modified Files
- `package.json` - Added `@astrojs/rss` dependency
- `src/pages/rss.xml.js` - Complete rewrite using official package
- `src/pages/hosts.astro` - Rewritten to use content collection
- `src/content/config.ts` - Added hosts collection, made coverImage optional
- `src/layouts/Base.astro` - Updated Episodes nav link
- `src/styles/theme.css` - Mobile header fixes

### Deprecated Files
- `src/lib/rss.ts` - No longer needed (replaced by @astrojs/rss)

## Asset Requirements

### Show Artwork
- **Path**: `public/images/cover.png`
- **Size**: 3000×3000 pixels (minimum 1400×1400)
- **Format**: PNG or JPEG
- **Must be**: Perfectly square
- **Used for**: RSS feed, episode fallback cover

### Host Avatars
- **Path**: `public/images/hosts/[name].jpg`
- **Recommended size**: 400×400 pixels or larger
- **Format**: JPG or PNG
- **Should be**: Square or circular crop

## GitHub Actions Compatibility

### Package Installation
The workflow should use either:
1. `npm ci` (requires updated `package-lock.json`)
2. `npm install` (more flexible, generates lock file)

To update lock file locally:
```bash
npm install @astrojs/rss
git add package.json package-lock.json
git commit -m "Add @astrojs/rss dependency"
```

## Testing Recommendations

### RSS Feed Validation
- Test with: [castfeedvalidator.com](https://castfeedvalidator.com)
- Check: [podba.se/validate](https://podba.se/validate)
- Verify: Image dimensions, enclosure URLs, iTunes tags

### Content Collection Testing
- Verify all host markdown files parse correctly
- Check slug generation matches expected URLs
- Test social links open in new tabs

### Mobile Testing
- Verify header doesn't overlay on small screens
- Check 2-column grid collapses to 1 on mobile
- Test navigation usability on touch devices

## Future Considerations

### RSS Feed
- Add chapters support if using `<podcast:chapters>` tag
- Consider transcript URLs in feed items
- Add guest information to episode metadata

### Hosts Collection
- Could add "featured" flag for homepage display
- Consider episodes-hosted count or list
- Add bio length limit or excerpt field for cards

### Episodes Page
- Add filtering by tag
- Add search functionality
- Add pagination if episode count grows large