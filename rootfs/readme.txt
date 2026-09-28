AntigravityFS commands:
  ls / dir          - list files
  cat <file>        - show a file
  touch <file>      - create an empty file
  write <file> <t>  - write text into a file
  rm <file>         - delete a file
  df                - disk usage

Files in the rootfs/ folder of the source tree are copied onto the disk
when the image is formatted (python tools/build.py --fresh).
