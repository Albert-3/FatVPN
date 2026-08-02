# Одноразовый CA для теста пиннинга

Три файла ниже — **не секреты**. Это самоподписанный CA, выпущенный на этой
машине 2026-08-02 специально для `test/ca_pinning_test.dart`, и приватный ключ
здесь лежит намеренно: тесту нужно поднять настоящий TLS-сервер, чтобы проверить,
что клиент приложения его **отвергает**.

| Файл | Что это |
|---|---|
| `other-ca.pem` | корень, которого нет и не будет ни в одном доверенном хранилище |
| `other-ca-server.pem` | лист на `localhost` (SAN `localhost`, `127.0.0.1`), подписан этим корнем |
| `other-ca-server-key.pem` | его ключ, без пароля |

Срок — 100 лет: тест не должен покраснеть в тот день, когда о нём все забыли.

Пересоздать (нужен `openssl`):

```sh
openssl req -x509 -newkey rsa:2048 -keyout other-ca-key.pem -out other-ca.pem \
  -days 36500 -nodes -subj "/CN=FatVPN test CA (not a real CA)" \
  -addext "basicConstraints=critical,CA:TRUE"
openssl req -newkey rsa:2048 -keyout other-ca-server-key.pem -out server.csr \
  -nodes -subj "/CN=localhost"
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n" > ext.cnf
openssl x509 -req -in server.csr -CA other-ca.pem -CAkey other-ca-key.pem \
  -CAcreateserial -out other-ca-server.pem -days 36500 -extfile ext.cnf
```

Ключ самого CA (`other-ca-key.pem`) в репозиторий не кладётся: он нужен только
при пересоздании, а лишний ключ — лишний повод для вопросов на ревью магазина.
