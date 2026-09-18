# [可选] 仅当 Microsoft Store 损坏需重注册时启用。
# 注意：wsreset -i 必须在线用户会话 + 网络，不能在离线映像执行，故放在首启脚本。
# 默认不执行（下方命令已注释）。需要时在 WinNTSetup 装完、进桌面后手动跑一次即可。
#
# Start-Process -FilePath 'wsreset.exe' -ArgumentList '-i' -Wait
