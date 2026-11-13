# iStore Pilot SVG Icon Library

- Version: 1.1.1
- Icon count: 76 SVG files
- Canvas: 24×24
- Stroke: 2px
- Line cap / join: round
- Fill: none by default
- Color: currentColor

## Contents
- `icons/`: individually importable SVGs, grouped by feature
- `icon-sprite.svg`: SVG symbol sprite (`ip-<icon-name>` IDs)
- `icon-manifest.json`: machine-readable metadata
- `icon.css`: size and semantic color helpers
- `preview/index.html`: offline visual preview
- `docs/ICON-MAPPING.md`: feature-to-icon mapping
- `docs/ICON-NAMES.txt`: plain-text icon name index

## Standalone SVG
```html
<img src="/assets/icons/monitoring/system-load.svg" width="24" height="24" alt="系统负载">
```
Note: SVG loaded through `img` does not inherit the host element's `currentColor`. Use inline SVG or the sprite when dynamic CSS coloring is required.

## Sprite
Inline the contents of `icon-sprite.svg` into the document, then:
```html
<svg class="ip-icon" aria-hidden="true"><use href="#ip-system-load" /></svg>
```

## Vue 3
```vue
<script setup lang="ts">
defineProps<{ name: string; size?: number }>()
</script>
<template>
  <svg :width="size ?? 24" :height="size ?? 24" class="ip-icon" aria-hidden="true">
    <use :href="`#ip-${name}`" />
  </svg>
</template>
```

## React
```tsx
type IconProps = { name: string; size?: number; className?: string }
export function Icon({ name, size = 24, className }: IconProps) {
  return <svg width={size} height={size} className={className} aria-hidden="true">
    <use href={`#ip-${name}`} />
  </svg>
}
```

Names use lowercase kebab-case. Icons do not hard-code brand colors; theme, disabled states, and animation belong to the consuming UI component.

## Network access modes
- `wired-connection`: 有线接入
- `wifi-2-4g`: 2.4GHz 无线接入
- `wifi-5g`: 5GHz 无线接入

These three icons represent connection media/bands. Connection state (connected, disconnected, connecting, error) should be expressed separately using status icons, not baked into the access-mode icon.
