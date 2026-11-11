/**
 * hanoutk — ربط التطبيق بقاعدة بيانات Supabase (تعدّد المحلات)
 * ---------------------------------------------------------------
 * ملاحظات:
 *  - استعمل مفتاح ANON فقط داخل التطبيق (مفتاح service_role يتجاوز RLS ولا يُوضع في المتصفح).
 *  - كل استعلام يمرّ عبر سياسات RLS: لا حاجة لكتابة store_id يدويًا في الاستعلام (يفرضه الخادم).
 *  - في وضع عدم الاتصال: يكتب التطبيق في IndexedDB كما هو، ثم يرسل عند عودة الإنترنت.
 */
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  }
)

/* ============ الحساب والمحل ============ */

export async function signIn(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw new Error(translate(error.message))
  return data.user
}

export async function signUpOwner({ email, password, fullName, storeName }) {
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: { data: { full_name: fullName, store_name: storeName } },
  })
  if (error) throw new Error(translate(error.message))
  // المحل + حساب المالك يُنشآن تلقائيًا عبر trigger handle_new_user
  return data.user
}

/** معلومات حساب المستخدم الحالي (المحل + الدور) */
export async function myProfile() {
  const { data: user } = await supabase.auth.getUser()
  if (!user) return null
  const { data, error } = await supabase
    .from('profiles')
    .select('id, store_id, role, full_name, phone, is_active')
    .eq('id', user.id)
    .single()
  if (error) throw new Error(translate(error.message))
  return data
}

export const isOwner = (profile) => profile?.role === 'owner'

/* ============ البيانات ============ */

export async function listProducts() {
  const { data, error } = await supabase
    .from('products')
    .select('*')
    .order('name', { ascending: true })
  if (error) throw new Error(translate(error.message))
  return data
}

export async function saveProduct(product) {
  const payload = {
    name: product.name,
    barcode: product.barcode || null,
    category: product.category || 'عام',
    sell_price: product.sellPrice ?? 0,
    buy_price: product.buyPrice ?? 0,
    units_per_box: product.unitsPerBox ?? 1,
    box_buy_price: product.boxBuyPrice ?? 0,
    box_sell_price: product.boxSellPrice ?? 0,
    unit_sell_price: product.unitSellPrice ?? 0,
    qty: product.qty ?? 0,
    min_stock: product.minStock ?? 5,
    is_active: product.isActive !== false,
  }
  const { data, error } = product.id
    ? await supabase.from('products').update(payload).eq('id', product.id).select().single()
    : await supabase.from('products').insert(payload).select().single()
  if (error) throw new Error(translate(error.message))
  return data
}

export async function deleteProduct(id) {
  const { error } = await supabase.from('products').delete().eq('id', id)
  if (error) throw new Error(translate(error.message))
}

/**
 * تسجيل بيع — القاعدة تحسب الإجمالي والتكلفة وتخصم المخزون.
 * ملاحظة: التكلفة تُؤخذ من المنتج في الخادم ولا يمكن تزويرها.
 */
export async function commitSale({ items, paid, method = 'cash', customerId = null, customerName = '', note = '' }) {
  const { data: sale, error } = await supabase
    .from('sales')
    .insert({ paid, method, customer_id: customerId, customer_name: customerName, note })
    .select()
    .single()
  if (error) throw new Error(translate(error.message))

  const rows = items.map((it) => ({
    sale_id: sale.id,
    product_id: it.productId,
    name: it.name,
    barcode: it.barcode || '',
    qty: it.qty,
    unit: it.unit || 'piece',
    units: it.units || 1,
    price: it.price,
  }))
  const { error: itemError } = await supabase.from('sale_items').insert(rows)
  if (itemError) throw new Error(translate(itemError.message))

  const { data: fresh } = await supabase.from('sales').select('*').eq('id', sale.id).single()
  return fresh
}

export async function undoSale(saleId) {
  const { error } = await supabase.from('sale_items').delete().eq('sale_id', saleId)
  if (error) throw new Error(translate(error.message))
  const { error: e2 } = await supabase.from('sales').delete().eq('id', saleId)
  if (e2) throw new Error(translate(e2.message))
}

export async function listCustomers() {
  const { data, error } = await supabase.from('customers').select('*').order('name')
  if (error) throw new Error(translate(error.message))
  return data
}

export async function listExpenses() {
  const { error } = await supabase.from('expenses').select('*')
  if (error) throw new Error(translate(error.message))
  return []
}

/* ============ العمال ============ */

export async function listStaff() {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name, role, phone, is_active, created_at')
    .order('created_at')
  if (error) throw new Error(translate(error.message))
  return data
}

export async function inviteStaff(email, role = 'staff') {
  const { error } = await supabase.from('staff_invitations').insert({ email, role })
  if (error) throw new Error(translate(error.message))
}

export async function setStaffActive(id, active) {
  const { error } = await supabase.from('profiles').update({ is_active: active }).eq('id', id)
  if (error) throw new Error(translate(error.message))
}

/* ============ المزامنة اللحظية (Realtime) ============ */

/** الاشتراك في تغيّرات محل معيّن (مبيعات/نشاط/مخزون) */
export function subscribeToStore(storeId, handlers = {}) {
  const channel = supabase.channel(`store-${storeId}`)
  if (handlers.onSale)
    channel.on('postgres_changes', { event: '*', schema: 'public', table: 'sales' }, handlers.onSale)
  if (handlers.onItem)
    channel.on('postgres_changes', { event: '*', schema: 'public', table: 'sale_items' }, handlers.onItem)
  if (handlers.onActivity)
    channel.on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'activity' }, handlers.onActivity)
  if (handlers.onProduct)
    channel.on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, handlers.onProduct)
  channel.subscribe()
  return () => supabase.removeChannel(channel)
}

/* ============ ترجمة الأخطاء ============ */
function translate(message = '') {
  const m = message.toLowerCase()
  if (m.includes('row-level security')) return 'غير مصرّح: البيانات تخصّ محلًا آخر'
  if (m.includes('duplicate key')) return 'هذا السجل موجود مسبقًا'
  if (m.includes('invalid login')) return 'البريد أو كلمة السر غير صحيحة'
  if (m.includes('email not confirmed')) return 'أكّد بريدك الإلكتروني أولًا'
  if (m.includes('permission denied')) return 'ليست لديك صلاحية لهذه العملية'
  if (m.includes('amount')) return 'القيمة غير صحيحة'
  return message
}
