# hanoutk — قاعدة بيانات Supabase (تعدّد المحلات)

دليل تشغيل مخطط قاعدة البيانات الجاهز لـ **hanoutk**، يدعم عدة محلات مستقلة تمامًا.

---

## 1) التثبيت (دقيقتان)

1. أنشئ مشروعًا في [supabase.com](https://supabase.com) (المشروع المجاني يكفي لبداية عدة محلات).
2. من القائمة **SQL Editor** ← New query.
3. افتح الملف `hanoutk-supabase.sql`، انسخه كاملًا، والصقه ثم **Run**.
4. تأكد من نجاح التثبيت — سترى `COMMIT` في النهاية، وستجد في جدول **Tables**:
   `stores`, `profiles`, `staff_invitations`, `products`, `categories`, `customers`,
   `sales`, `sale_items`, `expenses`, `payments`, `activity`.

> الملف قابل لإعادة التشغيل (يستخدم `create table if not exists` و`drop policy if exists`) — لا تخف من إعادة تطبيقه.

---

## 2) الحسابات والأدوار

| الدور | ما يستطيعه | ما لا يستطيعه |
|---|---|---|
| **owner (مالك)** | كل شيء: المنتجات، الأسعار، المصاريف، التقارير، العمال، حذف الفواتير | — |
| **staff (عامل)** | البيع، إضافة المنتجات والزبائن، تحصيل الديون، متابعة المخزون | **لا يرى** المصاريف ولا الأرباح، **لا يغيّر** الكميات ولا سعر الشراء، **لا يحذف** المنتجات |

### كيف يُنشأ حساب محل؟

- **المالك الجديد**: عند التسجيل في Supabase Auth يُنشأ له تلقائيًا **محل + حساب مالك** (trigger `handle_new_user`).
- **العامل**: المالك ينشئ **دعوة** من جدول `staff_invitations` (أو من لوحة hanoutk) بالبريد → العامل يسجّل بنفس البريد → يُربط تلقائيًا بمحل المالك بدور `staff`.

```sql
-- المالك ينشئ دعوة لعامل
insert into public.staff_invitations (store_id, email, role)
select id, 'amine@shop.dz', 'staff' from public.stores where name = 'محل النور';
```

---

## 3) نظام الأمان (RLS) — كيف يمنع التداخل بين المحلات

كل الجداول عليها `enable row level security`، وكل سياساتهم تعتمد على دالة واحدة:

```sql
public.current_store_id()  -- محل المستخدم الحالي (من profiles)
public.current_role()      -- دوره: owner أو staff
```

| القاعدة | التنفيذ |
|---|---|
| لا أحد يرى بيانات محل آخر | `using (store_id = public.current_store_id())` على كل جدول |
| لا أحد يكتب في محل آخر | Trigger `force_current_store` يفرض `store_id` من الحساب على كل INSERT |
| العامل لا يرى المصاريف | سياسة `expenses` مقيّدة بـ `public.is_owner()` |
| العامل لا يغيّر الكمية/سعر الشراء | Trigger `protect_product_sensitive_columns` يرفض التعديل |
| العامل لا يرفع نفسه إلى مالك | Trigger `protect_profile_privileges` يرفض تغيير `role`/`store_id` |
| التكلفة لا تُزوَّر | Trigger `on_sale_item_before` يأخذ `buy_price` من جدول المنتجات دائمًا |
| المخزون يُخصم بدقة | Trigger `on_sale_item_after` يخصم `qty × units` داخل نفس العملية |

### الاختبار الذاتي (مهم)

الملف `test-multitenancy.sql` يثبت عمليًا أن العزل يعمل — على جهازك أو على Supabase:

```bash
psql "postgresql://USER:PASSWORD@db.xxx.supabase.co:5432/postgres" -f test-multitenancy.sql
```

نتائج الاختبار المتوقعة (تم التحقق منها على PostgreSQL 15):

```
OK: إنشاء المتجر والملف تلقائيًا (stores=2, profiles=2)
OK: العامل انضمّ إلى محل ألف بدعوة (دور staff)
OK: عزل القراءة — مالك ألف يرى 1 منتج و1 زبون و1 مصروف فقط
OK: رُفضت الكتابة في محل آخر
OK: رُفض تعديل الكمية من العامل
OK: رُفض تعديل سعر الشراء من العامل
OK: رُفض ترقية العامل إلى مالك
OK: رُفض حذف المنتج من العامل
OK: البيع محسوب من القاعدة — مخزون=38.00, تكلفة=240.00, إجمالي=500.00
OK: مالك باء يرى 1 منتج و0 فاتورة فقط
```

---

## 4) المزامنة اللحظية (Realtime)

فعّل البثّ المباشر على جداول المبيعات والنشاط والمخزون:

```sql
alter publication supabase_realtime add table public.sales, public.activity, public.products;
```

في تطبيق hanoutk: بعد كل بيع يُرسَل السطر إلى `sale_items`، فيصل إلى شاشة المالك عبر Realtime خلال أجزاء من الثانية، وتُحدَّث الأرقام (المبيعات، المخزون، الديون) فورًا.

---

## 5) ربط التطبيق (JavaScript)

```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY   // مفتاح anon فقط — لا تستعمل service_role أبدًا
)

// 1) تسجيل الدخول (Supabase Auth)
await supabase.auth.signInWithPassword({ email, password })

// 2) قراءة منتجات محلي (سياسة RLS تتكفّل بالتصفية تلقائيًا)
const { data: products } = await supabase
  .from('products')
  .select('*')
  .eq('store_id', (await currentStoreId()))
  .order('name')

// 3) تسجيل بيع (التكلفة والمخزون يحسبهما قاعدة البيانات)
const { data: sale } = await supabase
  .from('sales')
  .insert({ store_id: storeId, paid: 1000, method: 'cash', customer_id: null })
  .select()
  .single()

await supabase.from('sale_items').insert({
  store_id: storeId,
  sale_id: sale.id,
  product_id: product.id,
  qty: 2,
  unit: 'piece',
  units: 1,
  price: 250        // السعر من العميل — التكلفة تُؤخذ من القاعدة
})

// 4) البثّ اللحظي
supabase
  .channel('store-' + storeId)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'sales' }, (p) => {
    console.log('بيع جديد!', p.new)
  })
  .subscribe()
```

**ملاحظة أمنية**: `service_role` يتجاوز كل سياسات RLS — استعمله في الخادم (Edge Functions) فقط، ولا تضعه داخل التطبيق.

---

## 6) نقل بيانات hanoutk الحالية (من التخزين المحلي إلى Supabase)

بياناتك الحالية في متصفحك (IndexedDB). لترحيلها:

1. من التطبيق: **الإعدادات ← «⬇ تنزيل نسخة احتياطية»** → ينزل ملف JSON فيه كل البيانات + حساب المحل + رمزه.
2. أنشئ حساب المالك في Supabase (بريد + كلمة سر) → يُنشأ له محل تلقائيًا.
3. في **SQL Editor** نفّذ الاستيراد (استبدل القيم):

```sql
insert into public.products (store_id, name, barcode, sell_price, buy_price, qty, min_stock, category)
select (select id from public.stores limit 1), name, barcode, sell_price, buy_price, qty, min_stock, category
from jsonb_to_recordset(
  '[{"name":"منتج","barcode":"123","sell_price":100,"buy_price":50,"qty":10,"min_stock":5,"category":"عام"}]'::jsonb
) as x(name text, barcode text, sell_price numeric, buy_price numeric, qty numeric, min_stock int, category text);

-- وبنفس الطريقة للزبائن والمبيعات (و sale_items لكل فاتورة)
```

أو اربط التطبيق بـ Supabase واقرأ ملف النسخة الاحتياطية داخله ليُرسل السجلات تلقائيًا (وهذا أفضل عند وجود فروع كثيرة).

---

## 7) ملفات الحزمة

| الملف | المحتوى |
|---|---|
| `hanoutk-supabase.sql` | المخطط الكامل: الجداول + الدوال + الـ Triggers + سياسات RLS + الصلاحيات + العروض |
| `test-multitenancy.sql` | 12 اختبارًا فعليًا لعزل المحلات وصلاحيات الأدوار |
| `test-supabase-stub.sql` | محاكاة `auth.uid()` لتشغيل الاختبار على PostgreSQL محلي |
| `hanoutk-supabase-client.js` | ربط التطبيق بـ Supabase (تسجيل الدخول، البيع، Realtime) |
