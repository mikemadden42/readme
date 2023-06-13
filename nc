# transfer files
# on the receiver side
nc -l -p 1776 > file.tgz
# on the sender side
nc -w 4 192.168.1.250 1776 < file.tgz
