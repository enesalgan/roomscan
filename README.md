# RoomScan — LiDAR oda tarama + iş yönetimi (iOS) · Faz 1

Şubeler / firmalar ve bireysel kullanıcılar için: LiDAR ile oda tarar (duvar, kapı, pencere, objeler, 3D model),
fotoğraf çeker, adres ekler, işleri (job) takvim ve zamanlayıcıyla yönetir. 3 tarama ücretsiz, sonrası Pro abonelik
(Apple In-App Purchase). Her şey Supabase'e gider; Faz 2'deki web tasarımcısı (2020 Design Flex benzeri) bu veriyi okuyacak.

```
roomscan/
├── supabase/
│   ├── migrations/20261021000001_init.sql     # tablolar, RLS, storage bucket'ları, kredi/abonelik mantığı
│   └── functions/verify-apple-transaction/    # StoreKit 2 işlemini doğrulayıp aboneliği yazan Edge Function
└── ios/
    ├── project.yml                            # XcodeGen tanımı (→ RoomScan.xcodeproj üretir)
    ├── Config/Secrets.xcconfig                # SUPABASE_URL / SUPABASE_ANON_KEY (BURAYI DOLDUR)
    └── RoomScan/
        ├── App/          RoomScanApp (giriş noktası, tab bar), Config
        ├── Models/       DB satırlarının Codable karşılıkları
        ├── Services/     Supabase client, SessionStore (auth+profil+hak), Repository (CRUD/upload), StoreService (StoreKit 2)
        ├── Features/
        │   ├── Auth/     Giriş / kayıt (bireysel · firma · davet kodu)
        │   ├── Jobs/     İş listesi, iş detayı, iş düzenleme
        │   ├── Address/  MapKit adres arama + mevcut konum
        │   ├── Scan/     RoomPlan tarama akışı, özet hesaplama, USDZ önizleme (SceneKit + AR Quick Look)
        │   ├── Photos/   Kamera / galeri, grid, görüntüleyici
        │   ├── Timer/    İş başına süre tutma
        │   ├── Calendar/ Randevu takvimi
        │   ├── Settings/ Hesap, org, üyeler, davet kodları, plan
        │   └── Paywall/  Pro abonelik / kredi paketi satın alma
        └── Resources/    Info.plist (XcodeGen üretir), Products.storekit (test), Assets
```

## 1) Supabase kurulumu

1. supabase.com → **New project** (ad: `roomscan`, bölge: us-east-1).
2. SQL Editor'de `supabase/migrations/20261021000001_init.sql` dosyasını çalıştır (veya bana projeyi söyle, ben uygularım).
3. **Authentication → Providers → Email**: test aşamasında "Confirm email" kapatılabilir (açıksa kayıt sonrası e-posta onayı gerekir).
4. Edge Function'ı yükle:
   ```bash
   npm i -g supabase
   supabase login
   supabase link --project-ref <PROJECT_REF>
   supabase functions deploy verify-apple-transaction
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` fonksiyonlara otomatik gelir.
5. Settings → API'den **Project URL** ve **anon/publishable key**'i al.

### Veri modeli (özet)
| Tablo | Ne tutar |
|---|---|
| `organizations` | Şube/firma veya bireysel hesap; `free_scans` (varsayılan 3) |
| `profiles` | Kullanıcı → org, rol (owner/admin/member) |
| `org_invites` | Owner/admin'in ürettiği davet kodları; kayıtta `invite_code` ile katılım |
| `jobs` | Müşteri, adres (+lat/lng), durum, randevu tarihi, tahmini tutar, notlar |
| `scans` | USDZ + CapturedRoom JSON + küçük resim yolları, ölçü özeti (JSONB), m² |
| `photos` | İş fotoğrafları |
| `time_entries` | Zamanlayıcı kayıtları |
| `subscriptions` / `scan_credits` | Apple abonelik ve kredi paketleri (sadece Edge Function yazar) |

RPC `my_entitlement()` → `{subscribed, scans_remaining, scans_used}`. `scans` tablosuna INSERT trigger'ı hakkı aşınca `SCAN_LIMIT_REACHED` hatası verir; uygulama bunu paywall'a çevirir.

Storage: `scans` ve `photos` bucket'ları özel; yol düzeni `{org_id}/{job_id}/{dosya}` ve RLS org'a göre.

## 2) iOS kurulumu (Mac)

```bash
brew install xcodegen
cd roomscan/ios
# Config/Secrets.xcconfig dosyasını doldur (URL'de "https:/$()/" yazımına dikkat — xcconfig'de // yorum sayılır)
xcodegen generate
open RoomScan.xcodeproj
```
- Xcode → Signing & Capabilities → Team seç. Capabilities'e **In-App Purchase** ekle.
- Paket çözümlemesi otomatik: `supabase-swift` (SPM).
- Gerçek cihaz gerekir (LiDAR: iPhone 12 Pro ve üstü Pro modeller, iPad Pro). Simülatörde tarama çalışmaz; diğer ekranlar çalışır.
- Scheme'de `Products.storekit` bağlı → satın alma akışı sandbox hesabı olmadan test edilebilir (bu durumda Edge Function imza doğrulamasını geçemez; gerçek test için TestFlight / Sandbox tester kullan).

## 3) App Store Connect

Ürünler (ID'ler `Config.swift` ve edge function içindeki `PRODUCTS` ile aynı olmalı):
- `com.lixisoft.roomscan.pro.monthly` — otomatik yenilenen abonelik
- `com.lixisoft.roomscan.pro.yearly` — otomatik yenilenen abonelik
- `com.lixisoft.roomscan.credits10` — tüketilebilir (10 tarama)

Fiyatları/ID'leri değiştirirsen üç yerde güncelle: App Store Connect, `Config.swift`, `index.ts`.

## 4) Akış

1. Kayıt: **Firma/Şube** (org oluşturur, owner olur) · **Davet kodu** (mevcut org'a üye) · **Bireysel**.
2. Jobs → `+` → müşteri, adres (arama ya da konumdan), randevu, tahmin.
3. İş detayı → **Scan a room with LiDAR** → tarama → "Done scanning" → RoomPlan 3D model üretir → isim ver → **Save & upload** (USDZ + JSON + thumbnail Supabase'e).
4. Fotoğraflar, zamanlayıcı, durum değişimi aynı ekranda. Takvim sekmesi randevuları gösterir.
5. 3 tarama bitince paywall; Apple'dan dönen imzalı işlem sunucuda doğrulanır ve org Pro olur (tüm şube personeli sınırsız).

## Faz 2 (web, 2020 Design Flex benzeri)
- Supabase'deki `scans.json_path` (CapturedRoom JSON) → duvar/kapı/pencere geometrisi; tarayıcıda Three.js ile 2D plan + 3D.
- Vita dolap kataloğu, sürükle-bırak yerleştirme, ölçü/fiyat hesabı.
- Aynı Supabase projesi, aynı auth; web tarafında org bazlı erişim hazır.

## Notlar / bilinen sınırlar
- Şu an çevrimiçi-öncelikli (internet gerekir). Offline kuyruk sonraki adım; tablolar `local_id` ile buna hazır.
- Çoklu oda birleştirme (RoomPlan `StructureBuilder`, iOS 17) sonraki adım; şimdilik her tarama tek oda.
- Edge function'daki Apple kök sertifika parmak izini yayına almadan önce apple.com/certificateauthority ile doğrula.
