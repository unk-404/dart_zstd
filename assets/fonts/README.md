# Fonts

`mplus-rounded.ttf` is **M PLUS Rounded 1c Regular** (weight 400), used only by
the benchmark chart renderer (`benchcat`) in CI.

- Source: https://github.com/google/fonts/tree/main/ofl/mplusrounded1c
- Upstream: https://github.com/coz-m/MPLUS_FONTS
- Designers: Coji Morishita, M+ Fonts Project
- Copyright: Copyright 2016 The Rounded M+ Project Authors
- License: SIL Open Font License 1.1, see [OFL.txt](OFL.txt)
- File size: 3,389,792 bytes
- SHA-256:
  `b75708b53e45b06d17d470aeeca5b766e3d1b3999f03f13ec4eb863ca846c14c`

It is a development-only asset and is excluded from the published package via
`.pubignore` (`assets/fonts/` is listed there). The chart text is Latin, so only
the Latin subset of the font is exercised.
