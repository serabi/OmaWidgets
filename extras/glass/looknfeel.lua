-- Frosted glass behind the OmaWidgets desktop cards only.
-- Blur has to be on globally for a layer rule to use it, so windows opt back out
-- to keep the rest of the desktop looking exactly as before.
hl.config({
  decoration = {
    blur = {
      enabled = true,
      size = 10,
      passes = 3,
      vibrancy = 0.25,
    },
  },
})
o.window({ class = ".*" }, { no_blur = true })
-- ignore_alpha keeps the blur inside the rounded cards instead of the full box.
hl.layer_rule({ match = { namespace = "omawidgets-desktop" }, blur = true, ignore_alpha = 0.05 })
