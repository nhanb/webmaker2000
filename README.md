Zig 0.13, assuming sdl2 & sqlite3 are installed on system:

```sh
zig build run -fsys=sdl2

# or, to watch:
find src | entr -rc zig build run -fsys=sdl2
```
