# labpc-claude-setup

研究室の共有 Windows 機(MS-1〜MS-4)の Lumerical / Zemax / COMSOL / RSoft を、Claude Code から本人のアカウントで使えるようにする準備一式。

- セットアップを頼まれたら: `SETUP.md` の手順に、上から順に従う。
- この台本や道具、スキルの雛形を直すときは: `README.md` の「開発する人向け」。`skill/` の `{{…}}` は `setup/labsetup.ps1 install` が埋める値なので、増やすときは `install` の `$values` にも足す。`*.ps1` は BOM 付きの UTF-8、`*.bat` は ASCII だけ(コマンド プロンプトは .bat を UTF-8 で読まない)で保存する。
