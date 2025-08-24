# Архитектурный документ для "Мобильный мир"

## Задание 7. Проектирование схем коллекций для шардирования данных

### Коллекция Orders


```js
{
    _id: ObjectId, 
    user_id: ObjectId,
    created_at: Date,
    items: [
        {
            product_id: ObjectId, 
            price: Number,
            quantity: Number,
        }
    ],
    status: String,
    total: Number
    geo: String
}
```

**Shard key:**
    user_id (hashed) - т.к основная нагрузка будет при поиске истории заказов конкретного пользователя.

**Основные операции:**

1. Быстрое создание заказов с одновременным списанием остатков.

    Здесь будем использовать транзакции т.к нам нужно выполнить действия одновременно в разных коллекциях

    Псевдокод:
    ```js
        startTransaction();

        createOrder(orderData);
        updateStocks(orderItems, region);

        commitTransaction();
    ```

2. Поиск истории заказов конкретного пользователя.

    ```js
        db.orders.find({ user_id: ObjectId("USER_ID")}).sort({ createdAt: -1 });
    ```
3. Отображение статуса заказа.

    ```js
        db.orders.find(
            { user_id: ObjectId("USER_ID")},
            { status: 1, total: 1, items: 1, _id: 0 })
        .sort({ createdAt: -1 });
    ```

### Коллекция Products

```js
{
  _id: ObjectId,
  name: String,        
  description: String, 
  price: Number,       
  stock: [
    {region: String, quantity: Number}
  ],       
  categories: [String],
  createdAt: Date,
  updatedAt: Date
  attributes: [String]
}
```

**Shard key:**
    _id (hashed) - т.к остатки по регионам у нас находятся прямо в коллекции нет смысла шардировать по гео, для поиска по категориям и цене можно использовать индексы. В дальнейшем лучше выделить stocks в отдельную коллекцию для оптимизации поиска и более равномерного распределения данных по шардам.

**Основные операции:**

1. Частые обновления остатков при покупках.
    ```js
        db.products.updateOne(
            { _id: ObjectId("..."), "stock.region": "ekaterinburg" },
            { $inc: { "stock.$.quantity": -2 } }
    );
    ```
   
2. Поиск товаров по категориям и фильтрация по диапазону цен.
    ```js
        db.products.find(
            { categories: "electronics", price: { $gte: 200, $lte: 400 }},
            {
             name: 1,
             price: 1,
             categories: 1,
             _id: 0
            }
        )
        .sort({ createdAt: -1 });
    ```
3. Описание товара на странице продукта.
    ```js
        db.orders.findOne(
            { _id: ObjectId("...")},
            {
                name: 1,
                description: 1,
                price: 1,
                categories: 1,
                stock: 1,
                attributes: 1,
                _id: 0
            }
        );
    ```

### Коллекция Carts

```js
{
    _id: ObjectId,
    user_id: ObjectId,
    session_id: ObjectId,
    items: [
        {
            product_id: ObjectId,
            quantity: Number
        }
    ],
    status: String,
    created_at: Date,
    updated_at: Date,
    expires_at: Date
}
```

**Shard key:**
    user_id (hashed) - т.к основная нагрузка будет при поиске корзины конкретного пользователя.

**Основные операции**

1. Создание корзины, когда заходит гость или новый пользователь.
    ```js
        db.carts.insertOne({
            user_id: null,                        
            session_id: "SESSION123",             
            status: "active",
            items: [],
            createdAt: new Date(),
            updatedAt: new Date()
        });
    ```
2. Получение текущей корзины по фильтру { session_id, status:"active" } или { user_id, status:"active" }.
    ```js
        db.carts.findOne({
            user_id: ObjectId("..."),                        
            status: "active",
        });
    ```

3. Добавление или замена товара в корзине.
    ```js
        db.carts.updateOne(
            { session_id: ObjectId("..."), status: "active" },
            {
              $set: { "items.$[elem]": { product_id: ObjectId("PROD_ID"), quantity: 3 } },
              $setOnInsert: { createdAt: new Date() },
              $currentDate: { updatedAt: true },
            },
            {
              arrayFilters: [{ "elem.product_id": ObjectId("PROD_ID") }]
            }
        );
    ```
4. Удаление товара из корзины.
    ```js
        db.carts.delete(
            { session_id: ObjectId("..."), status: "active" },
            { $pull: { items: { product_id: ObjectId("PROD_ID") } },
                $currentDate: { updatedAt: true }
            }
        );
    ```
5. Слияние гостевой корзины в пользовательскую, если пользователь залогинится:
    - прочитать гостевую { session_id, status:"active" };
    - добавить её items в корзину { user_id, status:"active" };
    - отметить гостевую как abandoned.

    ```js
        const guestCart = db.carts.findOne({
            session_id: ObjectId("..."),
            status: "active"
        });
    ```

    ```js
        db.carts.updateOne(
            { user_id: ObjectId("USER_ID"), status: "active" },
            {
              $push: { items: { $each: guestCart.items } },
              $currentDate: { updatedAt: true }
            }
        );
    ```

    ```js
        db.carts.updateOne(
            { session_id: ObjectId("..."), status: "active" },
            { $set: { status: "abandoned" }, $currentDate: { updatedAt: true } }
        );
    ```
6. Отметка корзины как заказанной.
    ```js
        db.carts.updateOne(
          { user_id: ObjectId("USER_ID"), status: "active" },
          { $set: { status: "ordered" }, $currentDate: { updatedAt: true } }
        );
    ```


## Задание 8. Выявление и устранение «горячих» шардов

Предположим, что у нас есть шардирование по категориям, и один из шардов перегрет. Задача научиться выявлять перегретые шарды и устранять такие проблемы. 

**Решение**

Добавить мониторинг:

- Количество чанков по каждому шарду
- Количество запросов (read/write) на шард
- Средняя latency запросов
- CPU и RAM по каждому шард-серверу
- Частота встречаемости значений ключа

**Улучшение стратегии шардирования** 

 - Применять bucketing для популярных категорий. Использовать Shard key:
    ```js
        { category: "Электроника", bucket: hash(productId) % N }
    ```

**Метрики и алерты для предотвращения инцидентов**

Дисбаланс чанков: если разница >20% между шардами → алерт.

CPU: загрузка >70% более 5 минут → алерт.

Latency: рост времени ответа >2х относительно среднего → алерт.

Частота ключей: если одно значение ключа встречается >50% в запросах → алерт и пересмотр стратегии шардирования.


## Задание 9. Настройка чтения с реплик и консистентность

### Коллекция Products

 - Можем читать с secondary
   - описание товара
   - фильтр по категориям и цене
   
**Причина:** устаревшая на несколько секунд информация о товарах допустима, не критично, что цена или атрибуты немного отстают.

 - Можем читать только с primary
   - чтение остатков
   - чтение актуальной цены
 
**Причина:** нужно избегать продажи товара, которого нет на складе.

**Допустимая задержка репликации**

≤ 1 секунды для чтений со secondary — товары не исчезнут мгновенно, но для поисковой выдачи это безопасно.

### Коллекция Orders

- Можем читать с secondary
   - история заказов
   
**Причина:** слегка устаревшая информация допустима; для истории нет риска бизнес-ошибки

 - Можем читать только с primary
   - чтение статуса заказа перед операциями списания или возврата
 
**Причина:** критично иметь актуальное состояние, чтобы не продать товар дважды и корректно вести workflow заказа

**Допустимая задержка репликации**

≤ 1 секунда для secondary read на историю заказов

### Коллекция Carts

- Можем читать с secondary
   - отображение данных корзины в UI
   
**Причина:** небольшая задержка допустима; пользователь не потеряет корзину

 - Можем читать только с primary
   - когда нужны актуальные данные
 
**Причина:** чтение с secondary может привести к race conditions или отображению устаревшей корзины

**Допустимая задержка репликации**

Secondary для чтения UI корзины — ≤ 0.5 секунда