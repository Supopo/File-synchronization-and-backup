# File-synchronization-and-backup
文件同步备份-方便将一些数据内容实时同步到备份盘

# 使用说明
将这ps1和bat两个文件放到源目录下，将PHOTO_BACKUP.ID放到备份盘！注意是备份盘！它主要用来检测盘是否存在的。
每次在源目录增删改之后，双击bat文件即可同步到备份目录下。
第一次运行之后会在源目录下生成json文件，这个不用删除，它里面扫描的文件信息。


# 修改源目录和备份目录
notepad++ 编辑ps1文件，
$SourceRoot = "G:\摄影"
$BackupRoot = "I:\备份\摄影"
$DriveMarker = "I:\PHOTO_BACKUP.ID"
自己修改就行。

为了防止中文乱码，ps1文件用UTF-8-BOM编码，bat文件用ANSI编码，所以要用编程工具打开，不能直接用记事本打开。
