# Взять самый свежий timestamp в переменную
```
BK=$(sudo ls -t /home/igor/backup/ | head -1)
echo "BK=$BK"
```
# Запустить
```
sudo bash /home/igor/cash-back/deploy-cashback/deploy-from-backup.sh /home/igor/backup/$BK
```
