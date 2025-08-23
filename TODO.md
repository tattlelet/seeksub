# CLI

## Usage


```
> seeksub --seek-only /.+?,/sg
/home/t/.config/nvim/init.lua:559
/home/t/.config/nvim/init.lua:560
/home/t/.config/nvim/init.lua:561
/home/t/.config/nvim/init.lua:562
```

```
cat <<- 'EOF' | seeksub 's///sg'
/home/t/.config/nvim/init.lua:559
/home/t/.config/nvim/init.lua:560
/home/t/.config/nvim/init.lua:561
/home/t/.config/nvim/init.lua:562
EOF
```

## TODO

- Read from stdin
  - map files
  - map ranges (sequential lines)
  - sort ranges
- read regex arg
- use pcre2 lib
- spit result to stdout
