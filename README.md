# Взять самый свежий timestamp в переменную
```
BK=$(sudo ls -t /home/igor/backup/ | head -1)
echo "BK=$BK"
```
# Запустить
```
sudo bash /home/igor/cash-back/deploy-cashback/deploy-from-backup.sh /home/igor/backup/$BK
```

# Первичный клон на прод-сервере (исключаем тесты)

На прод-сервере папки `tests/` и `postback/tests/` не нужны — они только
раздувают деплой и тащат за собой test-fixtures. Исключаем через
`git sparse-checkout` (одноразово после клона):

```
git clone <url> /home/igor/cash-back/deploy-cashback
cd /home/igor/cash-back/deploy-cashback
git sparse-checkout init --no-cone
git sparse-checkout set '/*' '!/tests/' '!/postback/tests/'
git read-tree -mu HEAD
```

После этого `git pull` не будет восстанавливать папки тестов.

Проверка:
```
ls tests          # No such file or directory
ls postback/tests # No such file or directory
cat .git/info/sparse-checkout
```

Если репозиторий уже клонирован без sparse-checkout — те же команды
применятся к существующему рабочему дереву и удалят `tests/` и
`postback/tests/` локально на сервере (в .git/ история сохраняется).
