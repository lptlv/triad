import ../types/projection_values as rv
import ../types/system_views
import pixel_buffer

export pixel_buffer

const Transparent = 0x00000000'u32

proc pointerDropPreviewCacheKey*(
    preview: PointerDropPreview, screen: rv.Rect, borderWidth: int32, color: uint32
): string =
  if not preview.found:
    return ""
  "pointer-drop-preview-v1:" & $uint32(preview.outputId) & ":" & $screen.x & ":" &
    $screen.y & ":" & $screen.w & ":" & $screen.h & ":" & $preview.rect.x & ":" &
    $preview.rect.y & ":" & $preview.rect.w & ":" & $preview.rect.h & ":" & $borderWidth &
    ":" & $color

proc drawPointerDropPreviewBuffer*(
    preview: PointerDropPreview,
    screen: rv.Rect,
    borderWidth: int32,
    color: uint32,
    buf: var PixelBuffer,
) =
  if not preview.found:
    return
  let thickness = max(2'i32, min(max(0'i32, borderWidth), 8'i32))
  buf.strokeRect(
    preview.rect.x - screen.x,
    preview.rect.y - screen.y,
    preview.rect.w,
    preview.rect.h,
    thickness,
    rgbaColorToArgb(color),
  )

proc renderPointerDropPreviewBuffer*(
    preview: PointerDropPreview, screen: rv.Rect, borderWidth: int32, color: uint32
): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Transparent)
  preview.drawPointerDropPreviewBuffer(screen, borderWidth, color, result)
