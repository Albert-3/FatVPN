# Одноразовый CA для теста пиннинга

Три файла ниже — **не секреты**. Это самоподписанный CA, выпущенный на этой
машине 2026-08-03 специально для `test/ca_pinning_test.dart`, и приватный ключ
сервера здесь лежит намеренно: тесту нужно поднять настоящий TLS-сервер, чтобы
проверить, что клиент приложения его **отвергает**.

| Файл | Что это |
|---|---|
| `other-ca.pem` | корень, которого нет и не будет ни в одном доверенном хранилище (25 лет) |
| `other-ca-server.pem` | лист на `localhost` (SAN `localhost`, `127.0.0.1`), подписан этим корнем |
| `other-ca-server-key.pem` | его ключ, без пароля |

## Почему лист живёт всего 398 дней

Первая версия этих файлов была выпущена на 100 лет — «тест не должен покраснеть в
тот день, когда о нём все забыли». Это и уронило сборку iOS в Codemagic
2026-08-03: контрольный тест «сервер со своим CA доступен» упал на macOS-раннере
с `CERTIFICATE_VERIFY_FAILED`, тогда как на Windows все прогоны были зелёные.

Причина не в пиннинге. Dart проверяет сертификаты через BoringSSL на Android,
Linux и Windows, но на всём, что от Apple, отдаёт проверку **SecTrust**
(`runtime/bin/security_context_macos.cc`; он же компилируется для iOS), а SecTrust
применяет политику Apple к любому серверному сертификату — **приватный CA от неё
не освобождает**. Наш лист нарушал её дважды:

- **не было `extendedKeyUsage=serverAuth`** — Apple требует его для сертификатов,
  выпущенных после 01.07.2019;
- **срок больше 825 дней** — потолок оттуда же. Послабление «398 дней» касается
  только корней, предустановленных в системе; приватным корням Apple разрешает до
  825 дней, но не больше.

398 дней выбраны сознательно: они проходят по обоим правилам сразу, без ставки на
то, что послабление для приватных корней распространяется и на анкоры, переданные
программно. Цена — перевыпуск примерно раз в год; чтобы он не выглядел как
«сломался пиннинг», в тесте стоит отдельная проверка срока с датой и ссылкой сюда.

## Перевыпустить (нужен `openssl`)

Дату из `notAfter` нового листа надо перенести в `_fixtureExpires`
(`test/ca_pinning_test.dart`). Ключ CA в репозиторий не кладётся — он нужен только
на время выпуска, поэтому корень перевыпускается вместе с листом. В Git Bash на
Windows перед этим: `export MSYS_NO_PATHCONV=1` (иначе `/CN=...` превращается в
путь).

```sh
openssl req -x509 -newkey rsa:2048 -keyout ca-key.pem -out other-ca.pem \
  -days 9125 -nodes -subj "/CN=FatVPN test CA (not a real CA)" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -keyout other-ca-server-key.pem -out server.csr \
  -nodes -subj "/CN=localhost"

printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n" > ext.cnf

openssl x509 -req -in server.csr -CA other-ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out other-ca-server.pem -days 398 -sha256 -extfile ext.cnf

rm -f ca-key.pem server.csr ext.cnf other-ca.srl
```

Проверить, что вышло:

```sh
openssl verify -CAfile other-ca.pem other-ca-server.pem
openssl x509 -in other-ca-server.pem -noout -dates \
  -ext subjectAltName,extendedKeyUsage,basicConstraints
```

Ключ самого CA (`ca-key.pem`) в репозиторий не кладётся: он нужен только при
перевыпуске, а лишний ключ — лишний повод для вопросов на ревью магазина.
