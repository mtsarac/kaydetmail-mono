# KaydetMail Test Planı

Bu doküman aşağıdaki iki repository incelenerek hazırlanmıştır:

- Backend: `mtsarac/mail-client` — .NET 10 + PostgreSQL + IMAP/SMTP
- Frontend: `nisaturk/kaydetmail` — Flutter
- Uygulama özellikleri: çoklu hesap, unified inbox, offline cache, IMAP/SMTP, OAuth, scheduled send, undo send/outbox, push notification, klasör/etiket yönetimi, arama, attachment, session/device yönetimi.

> Amaç: Fonksiyonel test, entegrasyon testi, hata senaryoları, güvenlik, performans ve regresyon testleri için uygulanabilir bir kontrol listesi oluşturmak.

---

## Öncelik Seviyeleri

- **P0 — Kritik:** Veri kaybı, yanlış hesaptan işlem, çift mail gönderimi, güvenlik açığı, login olmama gibi release blocker durumlar.
- **P1 — Yüksek:** Temel fonksiyonların yanlış veya kararsız çalışması.
- **P2 — Orta:** UX, edge-case veya ikincil fonksiyon sorunları.
- **P3 — Düşük:** Görsel/kozmetik veya düşük etkili sorunlar.

---

# 1. Smoke Testleri

- [ ] **P0** Uygulama temiz kurulumdan sonra açılıyor.
- [ ] **P0** Backend ayağa kalkıyor ve `/health/live` başarılı dönüyor.
- [ ] **P0** Backend `/health/ready` başarılı dönüyor.
- [ ] **P0** Flutter uygulaması backend'e bağlanabiliyor.
- [ ] **P0** Kullanıcı hesabına giriş yapılabiliyor.
- [ ] **P0** Gelen kutusu açılabiliyor.
- [ ] **P0** Bir mail detayı görüntülenebiliyor.
- [ ] **P0** Mail gönderilebiliyor.
- [ ] **P0** Gelen mail senkronize olabiliyor.
- [ ] **P1** Uygulama kapatılıp tekrar açıldığında oturum korunuyor.
- [ ] **P1** Logout işlemi başarılı çalışıyor.

---

# 2. Hesap Bağlama / Login

## Otomatik Keşif

- [ ] **P0** Geçerli mail adresi için IMAP/SMTP bilgileri otomatik bulunuyor.
- [ ] **P1** Geçersiz mail adresi doğru hata mesajı veriyor.
- [ ] **P1** Domain bulunamadığında uygulama kontrollü hata gösteriyor.
- [ ] **P1** IMAP var fakat SMTP yoksa doğru hata gösteriliyor.
- [ ] **P1** SMTP var fakat IMAP yoksa doğru hata gösteriliyor.
- [ ] **P1** TLS/SSL hatası kullanıcıya anlamlı biçimde gösteriliyor.

## Manuel Kurulum

- [ ] **P0** Doğru IMAP/SMTP host ve portlarıyla hesap eklenebiliyor.
- [ ] **P1** Yanlış IMAP host reddediliyor.
- [ ] **P1** Yanlış SMTP host reddediliyor.
- [ ] **P1** Yanlış port kombinasyonları reddediliyor.
- [ ] **P1** SSL/TLS seçeneği doğru uygulanıyor.
- [ ] **P0** SSRF açısından localhost/private/internal endpoint denemeleri kontrol ediliyor.
- [ ] **P1** DNS çözülemeyen sunucuda uygun hata gösteriliyor.

## Şifre

- [ ] **P0** Doğru şifre ile login başarılı.
- [ ] **P0** Yanlış şifre ile login başarısız.
- [ ] **P1** Arka arkaya yanlış şifre denemelerinde backend throttling/backoff uyguluyor.
- [ ] **P1** Yanlış şifreden sonra doğru şifre hemen denenebiliyor.
- [ ] **P1** Şifre değiştikten sonra `reconnect` akışı çalışıyor.

---

# 4. Access Token / Refresh Token

Backend tasarımında access token kısa ömürlü, refresh token ise rotate edilmektedir.

- [ ] **P0** Access token süresi dolduğunda refresh otomatik çalışıyor.
- [ ] **P0** Refresh sonrası kullanıcı mevcut ekranda kalıyor.
- [ ] **P0** Eski refresh token tekrar kullanıldığında reddediliyor.
- [ ] **P0** İki paralel API isteği aynı anda `401` aldığında refresh race-condition oluşmuyor.
- [ ] **P0** Refresh başarısız olduğunda kullanıcı güvenli biçimde login ekranına yönlendiriliyor.
- [ ] **P0** Logout sonrası eski access token ile işlem yapılamıyor.
- [ ] **P0** Logout sonrası eski refresh token kullanılamıyor.
- [ ] **P1** Uygulama restart sonrası refresh token doğru şekilde secure storage'dan okunuyor.

---

# 5. Çoklu Hesap

- [ ] **P0** Birden fazla mail hesabı eklenebiliyor.
- [ ] **P0** Hesaplar arasında geçiş yapılabiliyor.
- [ ] **P0** Bir hesaptaki mail başka hesapta görünmüyor.
- [ ] **P0** Bir hesabın klasörleri diğer hesapla karışmıyor.
- [ ] **P0** Bir hesabın label'ları diğer hesapta kullanılamıyor.
- [ ] **P0** Mail taşıma sırasında hedef klasör doğru hesaptan geliyor.
- [ ] **P0** Reply/send işlemi mailin ait olduğu hesaptan gönderiliyor.
- [ ] **P0** Yanlış sender identity kullanılarak mail gönderilemiyor.
- [ ] **P1** Bir hesaptan logout olmak diğer hesapların session'larını bozmuyor.
- [ ] **P1** Bir hesabın sync hatası diğer hesapları bloke etmiyor.

---

# 6. Unified Inbox — Tüm Gelen Kutuları

- [ ] **P0** Birden fazla hesabın mailleri tek listede gösteriliyor.
- [ ] **P1** Mail sıralaması hesaplardan bağımsız doğru tarih sırasına göre.
- [ ] **P0** Mail satırında hangi hesaba ait olduğu doğru belirleniyor.
- [ ] **P0** Unified inbox'tan mail açıldığında doğru account context kullanılıyor.
- [ ] **P0** Unified inbox'ta bulk selection farklı hesaplardan mail seçebiliyor.
- [ ] **P0** Mixed-account bulk move yalnız ortak standart klasörlere izin veriyor.
- [ ] **P1** Unified inbox araması hesaplar arasında doğru sonuç dönüyor.
- [ ] **P1** Hesap kaldırıldığında ilgili mailler unified inbox'tan temizleniyor.

---

# 7. Mail Senkronizasyonu

- [ ] **P0** Yeni mail backend tarafından senkronize ediliyor.
- [ ] **P0** Mail silinmesi server ve client arasında doğru yansıyor.
- [ ] **P0** Mail taşıma server ve client arasında doğru yansıyor.
- [ ] **P0** Read/unread durumu IMAP ile tutarlı.
- [ ] **P0** Star/flag durumu IMAP ile tutarlı.
- [ ] **P1** Pull-to-refresh sync bitmeden listeyi “tamamlandı” saymıyor.
- [ ] **P1** Sync sırasında internet kesilirse işlem recover edebiliyor.
- [ ] **P1** IMAP bağlantısı kesilip geri geldiğinde sync devam ediyor.
- [ ] **P1** Aynı mail duplicate olarak DB'ye yazılmıyor.
- [ ] **P1** UID/UIDVALIDITY değişikliği doğru ele alınıyor.
- [ ] **P1** Çok büyük mailbox sync edilebiliyor.
- [ ] **P1** Background sync ile manuel refresh çakışmıyor.
- [ ] **P2** Sync progress UI doğru güncelleniyor.

---

# 8. Inbox / Mail Listesi

- [ ] **P0** Gelen kutusu mailleri doğru listeliyor.
- [ ] **P1** Okunmuş/okunmamış görünümü doğru.
- [ ] **P1** Attachment göstergesi doğru.
- [ ] **P1** Star/pin göstergesi doğru.
- [ ] **P1** Sender ve subject doğru gösteriliyor.
- [ ] **P1** Tarih/saat doğru timezone ile gösteriliyor.
- [ ] **P1** Çok uzun subject UI'ı bozmuyor.
- [ ] **P1** Çok uzun sender adı UI'ı bozmuyor.
- [ ] **P2** Emoji içeren subject düzgün gösteriliyor.
- [ ] **P2** Unicode/Türkçe karakterler düzgün gösteriliyor.
- [ ] **P1** Pagination sırasında duplicate mail oluşmuyor.
- [ ] **P1** Scroll sonrası liste konumu gereksiz yere sıfırlanmıyor.

---

# 9. Mail Detayı

- [ ] **P0** Mail body doğru gösteriliyor.
- [ ] **P0** HTML mail render ediliyor.
- [ ] **P1** Plain text mail render ediliyor.
- [ ] **P1** Multipart mail doğru render ediliyor.
- [ ] **P1** Inline image doğru render ediliyor.
- [ ] **P1** Attachment listesi doğru gösteriliyor.
- [ ] **P1** Conversation/thread görüntüleniyor.
- [ ] **P1** Açılan mesaj conversation içinde ilk sırada tutuluyor.
- [ ] **P1** Eski mesajlar newest-to-oldest sıralanıyor.
- [ ] **P2** Çok uzun conversation performansı kabul edilebilir.
- [ ] **P2** Accessibility text scaling ile conversation okunabilir kalıyor.

---

# 10. Read / Unread

- [ ] **P0** Mail açıldığında read state beklenen şekilde değişiyor.
- [ ] **P0** “Okunmadı yap” çalışıyor.
- [ ] **P0** Read/unread backend ve IMAP'e yansıyor.
- [ ] **P1** Offline read/unread değişikliği reconnect sonrası reconcile oluyor.
- [ ] **P1** Server işlemi reddederse optimistic UI geri alınıyor.

---

# 11. Star / Pin

- [ ] **P1** Mail star/pin yapılabiliyor.
- [ ] **P1** Pin kaldırılabiliyor.
- [ ] **P1** Maksimum 3 eşzamanlı pin sınırı uygulanıyor.
- [ ] **P1** 4. pin girişimi doğru mesaj gösteriyor.
- [ ] **P1** Pinned mailler sanal “Yıldızlılar” klasöründe görünüyor.
- [ ] **P1** Offline pin işlemi reconnect sonrası synchronize oluyor.

---

# 12. Arşiv

- [ ] **P0** Mail archive edilebiliyor.
- [ ] **P0** Archive sonrası inbox'tan kalkıyor.
- [ ] **P1** Archive klasöründe görünüyor.
- [ ] **P0** Server archive işlemini reddederse UI rollback oluyor.
- [ ] **P1** Bulk archive çalışıyor.

---

# 13. Trash / Delete / Restore

- [ ] **P0** Mail trash'e taşınabiliyor.
- [ ] **P0** Trash'ten restore edilebiliyor.
- [ ] **P0** Kalıcı silme yalnız server onayından sonra UI'dan kaldırıyor.
- [ ] **P0** Server kalıcı silmeyi reddederse mail görünür kalıyor.
- [ ] **P0** Bulk delete partial failure doğru ele alınıyor.
- [ ] **P1** Swipe-to-delete ayarı açıkken swipe çalışıyor.
- [ ] **P1** Swipe-to-delete kapalıyken yanlışlıkla silme yapılmıyor.

---

# 14. Spam

- [ ] **P1** Mail spam klasörüne taşınabiliyor.
- [ ] **P1** Spam'den çıkarılabiliyor.
- [ ] **P1** Spam içindeki remote image'lar varsayılan olarak engelleniyor.
- [ ] **P1** Kullanıcı izin verirse normal remote image'lar açılıyor.
- [ ] **P0** Tracking pixel izin verilse bile engelli kalıyor.

---

# 15. Klasör Yönetimi

- [ ] **P0** Standart klasörler doğru algılanıyor.
- [ ] **P1** Custom folder oluşturulabiliyor.
- [ ] **P1** Nested folder oluşturulabiliyor.
- [ ] **P1** Custom folder yeniden adlandırılabiliyor.
- [ ] **P1** Custom folder silinebiliyor.
- [ ] **P1** Dolu klasör silme davranışı doğrulanıyor.
- [ ] **P1** Alt klasörü olan klasör silme reddediliyor.
- [ ] **P1** Klasör parent değiştirilebiliyor.
- [ ] **P0** Folder cycle oluşturma girişimi reddediliyor.
- [ ] **P1** Aynı isimli klasör collision doğru ele alınıyor.
- [ ] **P0** Standart/protected folder yanlışlıkla silinemiyor.
- [ ] **P1** IMAP server nested rename desteklemiyorsa local parent override düzgün çalışıyor.
- [ ] **P1** Folder refresh local parent override'ı bozmuyor.

---

# 16. Label Yönetimi

- [ ] **P1** Label oluşturulabiliyor.
- [ ] **P1** Label adı değiştirilebiliyor.
- [ ] **P1** Label rengi değiştirilebiliyor.
- [ ] **P1** Label silinebiliyor.
- [ ] **P1** Mail'e label eklenebiliyor.
- [ ] **P1** Mail'den label kaldırılabiliyor.
- [ ] **P0** Başka hesaba ait label mail'e atanamıyor.
- [ ] **P1** Offline label değişikliği reconnect sonrası synchronize oluyor.
- [ ] **P1** Server reject durumunda optimistic UI rollback oluyor.

---

# 17. Bulk Actions

- [ ] **P0** Birden fazla mail seçilebiliyor.
- [ ] **P0** Bulk read/unread çalışıyor.
- [ ] **P0** Bulk archive çalışıyor.
- [ ] **P0** Bulk trash çalışıyor.
- [ ] **P0** Bulk move çalışıyor.
- [ ] **P1** Bulk label işlemi çalışıyor.
- [ ] **P0** Partial failure durumunda yalnız başarısız mailler eski state'te kalıyor.
- [ ] **P1** Seçili olmayan thread sibling'larına işlem uygulanmıyor.
- [ ] **P1** Selection mode çıkışında state temizleniyor.

---

# 18. Mail Arama

- [ ] **P0** Subject araması çalışıyor.
- [ ] **P0** Body/text araması çalışıyor.
- [ ] **P1** Sender (`from`) filtresi çalışıyor.
- [ ] **P1** Recipient (`to`) filtresi çalışıyor.
- [ ] **P1** Folder filtresi çalışıyor.
- [ ] **P1** Label filtresi çalışıyor.
- [ ] **P1** Read/unread filtresi çalışıyor.
- [ ] **P1** Star/flag filtresi çalışıyor.
- [ ] **P1** Attachment filtresi çalışıyor.
- [ ] **P1** Date range filtresi çalışıyor.
- [ ] **P1** Birden fazla filtrenin AND kombinasyonu doğru.
- [ ] **P1** Local index'te olmayan eski mail remote IMAP search ile bulunabiliyor.
- [ ] **P1** Remote search incomplete ise devam çağrıları doğru çalışıyor.
- [ ] **P1** Arama sonucu yanlış hesaptan mail içermiyor.
- [ ] **P2** Boş arama düzgün ele alınıyor.
- [ ] **P2** Çok uzun arama sorgusu UI/API'ı bozmaz.

---

# 19. Compose — Yeni Mail

- [ ] **P0** Yeni mail oluşturulabiliyor.
- [ ] **P0** Tek alıcıya gönderilebiliyor.
- [ ] **P0** Birden fazla `To` alıcısına gönderilebiliyor.
- [ ] **P1** CC çalışıyor.
- [ ] **P1** BCC çalışıyor.
- [ ] **P0** Geçersiz mail adresi validation hatası veriyor.
- [ ] **P1** Boş subject ile gönderim davranışı doğrulanıyor.
- [ ] **P0** Boş recipient ile gönderim engelleniyor.
- [ ] **P1** Unicode/Türkçe subject gönderilebiliyor.
- [ ] **P1** HTML/rich-text içerik gönderilebiliyor.
- [ ] **P1** Çok uzun body limitleri doğru uygulanıyor.
- [ ] **P0** Gönder butonuna hızlıca iki kez basmak duplicate mail üretmiyor.

---

# 20. Idempotency

Gönderim endpoint'lerinde `Idempotency-Key` kritik bir güvenlik mekanizmasıdır.

- [ ] **P0** Aynı `Idempotency-Key` ile aynı send tekrarlandığında duplicate mail gönderilmiyor.
- [ ] **P0** Aynı key farklı body ile kullanılırsa conflict dönüyor.
- [ ] **P0** Aynı key farklı recipient ile kullanılırsa conflict dönüyor.
- [ ] **P0** Aynı key farklı read-receipt seçeneğiyle kullanılırsa conflict dönüyor.
- [ ] **P0** Boş idempotency key reddediliyor.
- [ ] **P1** 200 karakter üzeri key reddediliyor.
- [ ] **P0** Client network timeout sonrası send retry duplicate mail oluşturmuyor.

---

# 21. Reply / Reply All / Forward

- [ ] **P0** Reply doğru kişiye gidiyor.
- [ ] **P0** Reply All tüm gerekli kişileri ekliyor.
- [ ] **P1** Kullanıcının kendi mail adresi Reply All'da gereksiz duplicate olmuyor.
- [ ] **P0** Forward doğru body ve attachment'ları hazırlıyor.
- [ ] **P1** Quoted history doğru ekleniyor.
- [ ] **P1** Reply için yeni yazı alanında 5 boş satır davranışı doğrulanıyor.
- [ ] **P1** Reply signature doğru yerde.
- [ ] **P1** Forward signature doğru yerde.
- [ ] **P1** Eski mesajın action menüsü yalnız ilgili message'a işlem uyguluyor.

---

# 22. Signature

- [ ] **P1** Signature oluşturulabiliyor.
- [ ] **P1** Signature düzenlenebiliyor.
- [ ] **P1** Signature silinebiliyor.
- [ ] **P1** New mail default signature uygulanıyor.
- [ ] **P1** Reply default signature uygulanıyor.
- [ ] **P1** Forward default signature uygulanıyor.
- [ ] **P1** Signature değiştirilebiliyor.
- [ ] **P1** Draft tekrar açıldığında signature duplicate olmuyor.
- [ ] **P1** Undo send sonrası compose'a dönüşte signature duplicate olmuyor.

---

# 23. Sender Identity

- [ ] **P0** Varsayılan hesap adresiyle mail gönderilebiliyor.
- [ ] **P1** Tanımlı identity seçilebiliyor.
- [ ] **P0** Identity başka hesaba aitse kullanılamıyor.
- [ ] **P1** Reply'da uygun identity otomatik seçiliyor.
- [ ] **P1** Gönderilen mailde From header doğru.

---

# 24. Attachment

- [ ] **P0** Dosya attachment eklenebiliyor.
- [ ] **P1** Kamera üzerinden attachment eklenebiliyor.
- [ ] **P1** Galeriden attachment eklenebiliyor.
- [ ] **P1** Birden fazla attachment eklenebiliyor.
- [ ] **P0** Maksimum attachment sayısı uygulanıyor.
- [ ] **P0** Maksimum attachment boyutu uygulanıyor.
- [ ] **P1** 0-byte dosya davranışı test ediliyor.
- [ ] **P1** Çok uzun dosya adı test ediliyor.
- [ ] **P1** Türkçe/Unicode dosya adı test ediliyor.
- [ ] **P1** Aynı isimde iki dosya eklenebiliyor.
- [ ] **P0** Upload sırasında internet kesilirse compose verisi kaybolmuyor.
- [ ] **P0** Attachment upload başarısızsa “mail gönderildi” gösterilmiyor.
- [ ] **P1** Attachment download çalışıyor.
- [ ] **P1** Range/partial download desteklenen depolamada doğru çalışıyor.
- [ ] **P1** Büyük attachment memory problemi yaratmıyor.

---

# 25. Draft

- [ ] **P0** Compose içeriği draft olarak kaydedilebiliyor.
- [ ] **P0** Draft uygulama kapanıp açıldıktan sonra duruyor.
- [ ] **P0** Draft body kaybolmuyor.
- [ ] **P0** Draft recipient bilgileri korunuyor.
- [ ] **P0** Draft subject korunuyor.
- [ ] **P0** Draft attachment metadata korunuyor.
- [ ] **P1** Draft düzenlenebiliyor.
- [ ] **P1** Draft silinebiliyor.
- [ ] **P0** Draft send başarılı olduğunda draft kaldırılıyor.
- [ ] **P0** Draft send timeout/retry duplicate mail üretmiyor.
- [ ] **P0** Background draft sync başarısız olursa local draft bozulmuyor.
- [ ] **P1** Sync başarısız draft tekrar açıldığında kullanıcı uyarılıyor.

---

# 26. Undo Send / Outbox

- [ ] **P0** Send sonrası configured undo süresi boyunca mail gerçekten gönderilmiyor.
- [ ] **P0** Undo yapılırsa mail compose'a geri dönüyor.
- [ ] **P0** Undo sonrası body korunuyor.
- [ ] **P0** Undo sonrası attachment korunuyor.
- [ ] **P1** Undo sonrası signature duplicate olmuyor.
- [ ] **P0** Undo süresi dolduktan sonra mail yalnız bir kez gönderiliyor.
- [ ] **P0** Pre-delivery failure durumunda mail outbox'ta kalıyor.
- [ ] **P1** Failed mail retry edilebiliyor.
- [ ] **P1** Failed mail edit edilebiliyor.
- [ ] **P0** Delivery status belirsizse otomatik resend yapılmıyor.
- [ ] **P0** Delivery unknown durumda kullanıcıya başarı toast'ı gösterilmiyor.

---

# 27. Scheduled Send

- [ ] **P0** Gelecek zamana mail planlanabiliyor.
- [ ] **P0** Uygulama kapalıyken scheduled send gönderiliyor.
- [ ] **P0** Telefon internetsiz olsa bile backend scheduled send'i gerçekleştirebiliyor.
- [ ] **P1** Scheduled send listede görünüyor.
- [ ] **P1** Pending scheduled send düzenlenebiliyor.
- [ ] **P1** Pending scheduled send iptal edilebiliyor.
- [ ] **P0** Dispatch başlamış mail düzenlenemiyor.
- [ ] **P0** Failed scheduled send otomatik duplicate resend yapmıyor.
- [ ] **P1** Failed scheduled send reschedule edilebiliyor.
- [ ] **P0** DeliveryUnknown scheduled send otomatik resend edilmiyor.
- [ ] **P0** Aynı scheduled request idempotency key ile duplicate schedule oluşturmuyor.
- [ ] **P1** Past timestamp reddediliyor.
- [ ] **P1** Timezone/DST senaryoları doğru çalışıyor.
- [ ] **P1** Scheduled send attachment'ları gönderim zamanına kadar korunuyor.
- [ ] **P1** Scheduled send için receipt kısıtları UI ve backend'de tutarlı.

---

# 28. Read Receipt / Delivery Receipt

- [ ] **P1** Read receipt açık gönderimde ilgili header oluşuyor.
- [ ] **P1** Read receipt kapalı gönderimde header oluşmuyor.
- [ ] **P1** Recipient/provider receipt'i desteklemiyorsa gönderim yine başarılı.
- [ ] **P1** DSN desteklemeyen SMTP server gönderimi bozmaz.
- [ ] **P1** Başarılı receipt report'ları normal inbox mail'i olarak gösterilmiyor.
- [ ] **P1** Failed/delayed bounce mesajları normal mail olarak görünür.

---

# 29. Offline Mode

- [ ] **P0** Backend kapalıyken daha önce yüklenmiş inbox açılabiliyor.
- [ ] **P0** Cached mail body offline görüntülenebiliyor.
- [ ] **P1** Offline cold start hızlı açılıyor.
- [ ] **P0** Offline pin işlemi queue'ya alınabiliyor.
- [ ] **P0** Offline snooze işlemi queue'ya alınabiliyor.
- [ ] **P0** Offline label işlemi queue'ya alınabiliyor.
- [ ] **P1** Offline contact değişikliği queue'ya alınabiliyor.
- [ ] **P0** İnternet gelince queued işlemler backend ile reconcile oluyor.
- [ ] **P0** Server reject ettiği queued işlem local state'i düzeltiyor.
- [ ] **P0** Aynı offline mutation iki kez uygulanmıyor.
- [ ] **P1** Offline cache eski veri olduğunu kullanıcıdan gizlemiyor.
- [ ] **P0** Local SQLite cache encryption doğrulanıyor.
- [ ] **P0** Attachment byte'larının local mail cache'e beklenmedik şekilde yazılmadığı doğrulanıyor.

---

# 30. Network Hata Senaryoları

Aşağıdaki işlemler sırasında bağlantı kesilerek test edilmelidir:

- [ ] **P0** Login sırasında.
- [ ] **P0** Mail send sırasında.
- [ ] **P0** Attachment upload sırasında.
- [ ] **P0** Draft sync sırasında.
- [ ] **P0** Mail move sırasında.
- [ ] **P0** Delete sırasında.
- [ ] **P1** Search sırasında.
- [ ] **P1** Folder refresh sırasında.
- [ ] **P1** Push registration sırasında.
- [ ] **P1** Token refresh sırasında.
- [ ] **P1** Attachment download sırasında.

Her senaryoda aşağıdakiler kontrol edilmeli:

- [ ] UI sonsuz loading'e girmiyor.
- [ ] Kullanıcı verisi kaybolmuyor.
- [ ] Duplicate işlem oluşmuyor.
- [ ] Retry güvenli.
- [ ] Hata mesajı anlaşılır.
- [ ] Reconnect sonrası state toparlanıyor.

---

# 31. Push Notification

- [ ] **P0** Yeni mail push geliyor.
- [ ] **P1** App foreground iken local notification gösteriliyor.
- [ ] **P0** App background iken notification geliyor.
- [ ] **P0** App tamamen kapalıyken notification geliyor.
- [ ] **P0** Notification tap doğru maili açıyor.
- [ ] **P0** Notification başka hesaba aitse doğru account context açılıyor.
- [ ] **P1** Mail silinmişse notification tap crash oluşturmuyor.
- [ ] **P1** Push token register ediliyor.
- [ ] **P1** Push token değişince backend güncelleniyor.
- [ ] **P1** Notification privacy `Full` doğru çalışıyor.
- [ ] **P1** Notification privacy `Limited` doğru çalışıyor.
- [ ] **P1** Notification privacy `Private` doğru çalışıyor.
- [ ] **P1** Inbox-only notification ayarı doğru.
- [ ] **P1** Notification disabled iken yeni mail push gelmiyor.
- [ ] **P1** Reauthentication gibi hesap uyarıları gerekli durumda yine geliyor.

---

# 32. Session / Bağlı Cihazlar

- [ ] **P0** Aynı hesap iki cihazda login olabiliyor.
- [ ] **P1** Bağlı cihazlar listesi doğru.
- [ ] **P1** Current device doğru işaretleniyor.
- [ ] **P0** Başka cihaz session'ı revoke edilebiliyor.
- [ ] **P0** Revoke edilen cihaz access token süresi bitince refresh yapamıyor.
- [ ] **P0** Revoke edilen cihaz tekrar yetkili API çağrısı yapamıyor.
- [ ] **P1** Bir cihaz logout olduğunda diğer cihaz çalışmaya devam ediyor.

---

# 33. Remote Image / Privacy

- [ ] **P1** Normal mailde remote image varsayılan davranışa göre yükleniyor.
- [ ] **P0** Junk mailde remote image varsayılan olarak engelleniyor.
- [ ] **P0** `dmarc=fail` mailde remote image varsayılan olarak engelleniyor.
- [ ] **P1** Kullanıcı “remote content allow” yaptığında normal image yükleniyor.
- [ ] **P0** Tracking pixel her durumda engelleniyor.
- [ ] **P0** `display:none` tracking image engelleniyor.
- [ ] **P0** 1x1 pixel image engelleniyor.
- [ ] **P0** Script tag çalıştırılmıyor.
- [ ] **P0** Inline event handler (`onclick`, `onerror` vb.) çalıştırılmıyor.
- [ ] **P0** `javascript:` URL engelleniyor.
- [ ] **P0** Remote iframe/object/embed içerikleri çalıştırılmıyor.
- [ ] **P1** Engellenen remote content kullanıcıya uygun şekilde bildiriliyor.

---

# 34. HTML / XSS Güvenliği

Test mailleri hazırlanmalı:

- [ ] **P0** `<script>alert(1)</script>`
- [ ] **P0** `<img src=x onerror=...>`
- [ ] **P0** `<a href="javascript:...">`
- [ ] **P0** SVG script payload.
- [ ] **P0** CSS tabanlı tracking girişimi.
- [ ] **P0** iframe.
- [ ] **P0** object/embed.
- [ ] **P0** form submit.
- [ ] **P0** data URI edge-case.
- [ ] **P0** malformed HTML.

Beklenen sonuç:

- [ ] Hiçbir executable içerik çalışmamalı.
- [ ] Mail uygulama context'inden token/credential okuyamamalı.
- [ ] Mail içeriği uygulamanın navigation/state yapısını etkileyememeli.

---

# 35. Original Headers / Raw MIME

- [ ] **P1** Original headers görüntülenebiliyor.
- [ ] **P1** Raw MIME görüntülenebiliyor/indirilebiliyor.
- [ ] **P1** Offline iken gerekli IMAP bağlantısı olmadığı durumda doğru hata gösteriliyor.
- [ ] **P1** UIDVALIDITY uyuşmazlığında kontrollü hata dönüyor.
- [ ] **P0** Başka hesaba ait mail source'una erişilemiyor.
- [ ] **P1** Çok büyük MIME source uygulamayı kilitlemiyor.

---

# 36. SPF / DKIM / DMARC Gösterimi

- [ ] **P1** SPF pass doğru gösteriliyor.
- [ ] **P1** SPF fail doğru gösteriliyor.
- [ ] **P1** DKIM pass doğru gösteriliyor.
- [ ] **P1** DKIM fail doğru gösteriliyor.
- [ ] **P1** DMARC pass doğru gösteriliyor.
- [ ] **P1** DMARC fail doğru gösteriliyor.
- [ ] **P1** Authentication-Results olmayan mail düzgün gösteriliyor.
- [ ] **P1** UI bu sonuçları “backend yeniden doğruladı” gibi yanlış ifade etmiyor.

---

# 37. S/MIME / OpenPGP Gösterimi

- [ ] **P1** S/MIME signed mail algılanıyor.
- [ ] **P1** Valid signature doğru gösteriliyor.
- [ ] **P1** Invalid signature doğru gösteriliyor.
- [ ] **P1** Untrusted signature doğru gösteriliyor.
- [ ] **P1** Unverifiable signature doğru gösteriliyor.
- [ ] **P1** OpenPGP signed/encrypted indicator doğru.
- [ ] **P1** Uygulama desteklemediği OpenPGP verification/decryption'ı destekliyormuş gibi göstermiyor.

---

# 38. Templates

- [ ] **P1** Template oluşturulabiliyor.
- [ ] **P1** Template düzenlenebiliyor.
- [ ] **P1** Template silinebiliyor.
- [ ] **P1** Template compose'a eklenebiliyor.
- [ ] **P1** Duplicate template adı case-insensitive olarak reddediliyor.
- [ ] **P1** 100 karakterden uzun ad reddediliyor.
- [ ] **P1** Çok uzun subject reddediliyor.
- [ ] **P1** Hem text hem HTML body boş ise reddediliyor.
- [ ] **P0** Başka hesaba ait template erişilemiyor.

---

# 39. Snippets

- [ ] **P1** Snippet oluşturulabiliyor.
- [ ] **P1** Snippet düzenlenebiliyor.
- [ ] **P1** Snippet silinebiliyor.
- [ ] **P1** Snippet compose'a eklenebiliyor.
- [ ] **P1** Sort order doğru.
- [ ] **P1** Boş text reddediliyor.
- [ ] **P1** 2000 karakter üzeri text reddediliyor.
- [ ] **P0** Başka hesaba ait snippet erişilemiyor.

---

# 40. Share Sheet

- [ ] **P1** Android share sheet'ten text KaydetMail'e aktarılabiliyor.
- [ ] **P1** Dosya share edilerek compose açılabiliyor.
- [ ] **P1** Birden fazla dosya share senaryosu test ediliyor.
- [ ] **P1** Uygulama kapalıyken share intake çalışıyor.
- [ ] **P1** Uygulama background'dayken share intake çalışıyor.
- [ ] **P1** Share edilen içerik compose'da duplicate olmuyor.

---

# 41. Contact / Recipient UX

- [ ] **P1** Recipient input doğru validation yapıyor.
- [ ] **P1** Aynı recipient iki kez eklenemiyor veya normalize ediliyor.
- [ ] **P1** Büyük/küçük harf farkıyla duplicate recipient oluşmuyor.
- [ ] **P1** Contacts permission reddedilirse compose çalışmaya devam ediyor.
- [ ] **P1** Contacts permission verilirse öneriler çalışıyor.
- [ ] **P1** Geçersiz contact email kullanıcıya gösteriliyor ancak yanlışlıkla gönderilmiyor.

---

# 42. Account Quota

- [ ] **P2** IMAP QUOTA destekleyen server doğru used/limit gösteriyor.
- [ ] **P2** QUOTA desteklemeyen server UI'ı bozmuyor.
- [ ] **P2** Mail server unavailable olduğunda quota ekranı kontrollü hata gösteriyor.
- [ ] **P2** Byte/KiB dönüşümü doğru.

---

# 43. Sync Scope

- [ ] **P1** InboxAndSent scope doğru.
- [ ] **P1** AllFolders scope doğru.
- [ ] **P1** SelectedFolders scope doğru.
- [ ] **P1** SelectedFolders en az bir klasör gerektiriyor.
- [ ] **P0** Başka hesaba ait folder ID kabul edilmiyor.
- [ ] **P1** Yeni oluşturulan klasör mevcut sync scope davranışına uygun işleniyor.

---

# 44. Snooze

- [ ] **P1** Mail snooze edilebiliyor.
- [ ] **P1** Snooze zamanı dolunca mail geri geliyor.
- [ ] **P1** Snooze notification tek kez geliyor.
- [ ] **P1** Snooze zamanı ileri alınabiliyor.
- [ ] **P1** Snooze iptal edilebiliyor.
- [ ] **P0** İptal edilen snooze daha sonra yanlışlıkla tetiklenmiyor.
- [ ] **P1** Offline snooze reconnect sonrası synchronize oluyor.

---

# 45. API Validation

- [ ] **P0** Bozuk JSON `400` döndürüyor.
- [ ] **P1** Eksik required field doğru problem-details dönüyor.
- [ ] **P1** Yanlış data type doğru hata dönüyor.
- [ ] **P1** Çok büyük payload kontrollü reddediliyor.
- [ ] **P1** Yarım multipart request kontrollü reddediliyor.
- [ ] **P1** Bilinmeyen enum değeri reddediliyor.
- [ ] **P0** Başka hesaba ait resource ID `404/403` benzeri güvenli sonuç dönüyor.
- [ ] **P1** Problem response'larda sabit `code` alanı mevcut.
- [ ] **P1** Frontend backend hata kodlarını kullanıcı dostu mesaja çevirebiliyor.

---

# 46. Rate Limit

Backend dokümantasyonunda hesap/IP başına rate limit bulunmaktadır.

- [ ] **P1** Limit aşılınca `429` dönüyor.
- [ ] **P1** Frontend `429` durumunda crash olmuyor.
- [ ] **P1** Kullanıcıya retry davranışı doğru sunuluyor.
- [ ] **P1** Bir hesabın rate limit'i başka hesabı gereksiz etkilemiyor.
- [ ] **P1** Anonymous endpoint rate limit davranışı doğrulanıyor.

---

# 47. Correlation ID / Observability

- [ ] **P1** Her API response `X-Correlation-ID` içeriyor.
- [ ] **P1** Client correlation ID gönderirse backend bunu trace edebiliyor.
- [ ] **P1** 500 hata loglarında correlation ID bulunuyor.
- [ ] **P0** Loglarda access token yok.
- [ ] **P0** Loglarda refresh token yok.
- [ ] **P0** Loglarda mail body/credential gibi hassas veri gereksiz tutulmuyor.
- [ ] **P1** Crashlytics uncaught Flutter error'larını kaydediyor.
- [ ] **P1** Firebase Performance `api_http` trace üretiyor.
- [ ] **P0** Performance trace mail içeriği/token/account identifier içermiyor.

---

# 48. Backend Health / Dependency Failure

- [ ] **P0** PostgreSQL kapalıyken readiness failure veriyor.
- [ ] **P1** PostgreSQL geri geldiğinde backend toparlanıyor.
- [ ] **P1** IMAP server unavailable iken API kontrollü hata veriyor.
- [ ] **P1** SMTP unavailable iken mail yanlışlıkla success görünmüyor.
- [ ] **P1** Attachment storage unavailable iken doğru hata veriliyor.
- [ ] **P1** Firebase unavailable iken mail sistemi çalışmaya devam ediyor.
- [ ] **P1** Background worker exception backend'i tamamen düşürmüyor.
- [ ] **P1** Scheduled-send worker restart sonrası pending işleri sürdürüyor.

---

# 49. Database / Veri Tutarlılığı

- [ ] **P0** Aynı IMAP mail duplicate DB kaydı oluşturmuyor.
- [ ] **P0** Account delete ilişkili verileri beklenen şekilde temizliyor.
- [ ] **P0** Account A verisi Account B sorgularında görünmüyor.
- [ ] **P0** Transaction yarıda kesilirse yarım state oluşmuyor.
- [ ] **P1** Migration temiz DB üzerinde çalışıyor.
- [ ] **P1** Migration mevcut DB üzerinde data loss olmadan çalışıyor.
- [ ] **P1** Backend restart sonrası sync state korunuyor.
- [ ] **P1** Background encryption/backfill işlemleri idempotent çalışıyor.

---

# 50. Güvenlik — Yetkilendirme

- [ ] **P0** Token olmadan protected endpoint'ler açılamıyor.
- [ ] **P0** Geçersiz JWT reddediliyor.
- [ ] **P0** Expired JWT reddediliyor.
- [ ] **P0** Account A token'ı ile Account B mailine erişilemiyor.
- [ ] **P0** Account A token'ı ile Account B attachment'ı indirilemiyor.
- [ ] **P0** Account A token'ı ile Account B folder değiştirilemiyor.
- [ ] **P0** Account A token'ı ile Account B session revoke edilemiyor.
- [ ] **P0** Management endpoint'ler normal JWT ile açılamıyor.
- [ ] **P0** Management API key yanlışsa erişim reddediliyor.
- [ ] **P0** Management kapalıysa endpoint erişilemiyor.

---

# 51. Güvenlik — Credential Storage

- [ ] **P0** Mail şifresi plaintext DB'de tutulmuyor.
- [ ] **P0** OAuth token plaintext olarak client loglarında görünmüyor.
- [ ] **P0** Refresh token frontend secure storage dışında saklanmıyor.
- [ ] **P0** Local encrypted SQLite cache gerçekten şifreli.
- [ ] **P0** Android backup/debug dump üzerinden credential kolayca elde edilemiyor.
- [ ] **P1** Logout sonrası gerekli local sensitive state temizleniyor.
- [ ] **P1** Account delete sonrası ilgili local cache temizleniyor.

---

# 52. UI / UX

- [ ] **P1** Loading state'leri doğru.
- [ ] **P1** Empty inbox state doğru.
- [ ] **P1** Empty search state doğru.
- [ ] **P1** Error state'leri kullanıcıya anlaşılır.
- [ ] **P1** Retry butonları gerçekten retry yapıyor.
- [ ] **P2** Uzun metinlerde overflow yok.
- [ ] **P2** Landscape modunda ekran bozulmuyor.
- [ ] **P2** Küçük ekranlarda compose kullanılabilir.
- [ ] **P2** Büyük ekran/tablet'te layout kullanılabilir.
- [ ] **P2** Keyboard açıldığında recipient/body alanları erişilebilir.
- [ ] **P2** Back navigation compose verisini yanlışlıkla kaybettirmiyor.

---

# 53. Accessibility

- [ ] **P2** Büyük font ayarında UI kullanılabilir.
- [ ] **P2** Screen reader temel butonları okuyabiliyor.
- [ ] **P2** Icon-only butonların semantic label'ları var.
- [ ] **P2** Contrast seviyesi yeterli.
- [ ] **P2** Dynamic text scaling conversation ekranını bozmuyor.
- [ ] **P2** Touch target'lar yeterli boyutta.
- [ ] **P2** Renk tek başına state göstergesi olarak kullanılmıyor.

---

# 54. Android / iOS / Platform

## Android

- [ ] **P0** Debug build çalışıyor.
- [ ] **P0** Release build çalışıyor.
- [ ] **P1** Push notification çalışıyor.
- [ ] **P1** Camera permission çalışıyor.
- [ ] **P1** Gallery/file permission akışı çalışıyor.
- [ ] **P1** Local notification tap navigation çalışıyor.
- [ ] **P1** Share sheet intake çalışıyor.

## iOS

- [ ] **P0** Uygulama build ediliyor.
- [ ] **P1** OAuth callback çalışıyor.
- [ ] **P1** Attachment picker çalışıyor.
- [ ] **P1** APNs/Firebase yapılandırıldıysa push çalışıyor.
- [ ] **P1** Notification tap navigation çalışıyor.

---

# 55. Performans

- [ ] **P1** 1.000 mail içeren inbox kullanılabilir hızda açılıyor.
- [ ] **P1** 10.000+ mail mailbox senaryosu test ediliyor.
- [ ] **P1** Unified inbox büyük veriyle akıcı.
- [ ] **P1** Search response süreleri ölçülüyor.
- [ ] **P1** Uzun conversation render süresi ölçülüyor.
- [ ] **P1** Büyük HTML mail render süresi ölçülüyor.
- [ ] **P1** 20–50 MB attachment upload sırasında memory kullanımı ölçülüyor.
- [ ] **P1** Background sync sırasında UI donmuyor.
- [ ] **P1** Cold start süresi ölçülüyor.
- [ ] **P1** Offline-cache cold start süresi ölçülüyor.
- [ ] **P2** Pil tüketimi uzun background kullanımında ölçülüyor.

---

# 56. Backend Load / Concurrency

- [ ] **P1** Aynı hesap için eşzamanlı 20+ API request.
- [ ] **P1** Aynı anda birden fazla sync request.
- [ ] **P0** Aynı mail için eşzamanlı move/delete işlemi.
- [ ] **P0** Aynı draft için eşzamanlı update/send.
- [ ] **P0** Aynı scheduled send için eşzamanlı edit/cancel.
- [ ] **P0** Aynı idempotency key ile paralel send request.
- [ ] **P1** Çok sayıda account aynı anda sync olduğunda queue davranışı.
- [ ] **P1** IMAP connection limitine ulaşıldığında sistem kontrollü fallback yapıyor.

---

# 57. Crash / Recovery

Aşağıdaki anlarda uygulama force-close edilerek tekrar açılmalı:

- [ ] **P0** Mail yazarken.
- [ ] **P0** Draft save sırasında.
- [ ] **P0** Undo-send countdown sırasında.
- [ ] **P0** Attachment upload sırasında.
- [ ] **P0** Offline mutation queue oluşmuşken.
- [ ] **P1** Search sırasında.
- [ ] **P1** Folder move sırasında.

Kontrol:

- [ ] Kullanıcı verisi kaybolmuyor.
- [ ] Duplicate mail gönderilmiyor.
- [ ] Local state bozulmuyor.
- [ ] Uygulama tekrar açılabiliyor.

---

# 58. Backend Restart / Deployment Recovery

- [ ] **P0** Backend send öncesi restart olursa duplicate mail oluşmuyor.
- [ ] **P0** Backend scheduled send sırasında restart olursa mail en fazla bir kez gönderiliyor.
- [ ] **P1** Backend sync sırasında restart sonrası devam edebiliyor.
- [ ] **P1** Pending background jobs tekrar işleniyor.
- [ ] **P1** Health endpoint deployment boyunca doğru state'i yansıtıyor.
- [ ] **P1** DB migration başarısızsa servis yanlışlıkla ready olmuyor.

---

# 59. Mail Provider Uyumluluğu

En az aşağıdaki provider tipleriyle test önerilir:

- [ ] Gmail.
- [ ] Microsoft Outlook / Office 365.
- [ ] Yahoo benzeri klasik IMAP provider.
- [ ] GreenMail/local test server.
- [ ] Custom domain IMAP/SMTP.
- [ ] App-password gerektiren provider.
- [ ] OAuth zorunlu provider.
- [ ] IMAP IDLE desteklemeyen provider.
- [ ] QUOTA desteklemeyen provider.
- [ ] Nested folder davranışı farklı provider.

---

# 60. Test Mail Veri Seti

Otomasyon ve manuel QA için aşağıdaki test mailleri hazırlanmalıdır:

- [ ] Plain text mail.
- [ ] HTML mail.
- [ ] HTML + plain multipart mail.
- [ ] Inline image mail.
- [ ] Remote image mail.
- [ ] Tracking pixel mail.
- [ ] Script/XSS payload içeren mail.
- [ ] 1 attachment.
- [ ] Çoklu attachment.
- [ ] Büyük attachment.
- [ ] Unicode dosya adı.
- [ ] Türkçe subject/body.
- [ ] Emoji subject/body.
- [ ] Çok uzun subject.
- [ ] Çok uzun body.
- [ ] Deep conversation/thread.
- [ ] S/MIME signed mail.
- [ ] OpenPGP signed mail.
- [ ] DMARC fail mail.
- [ ] SPF fail mail.
- [ ] DKIM fail mail.
- [ ] Bounce/failed DSN mail.
- [ ] Read receipt mail.
- [ ] Nested quoted-history mail.

---

# 61. Otomasyon İçin Önerilen Katmanlar

## Backend Unit Test

Öncelikle:

- Token rotation
- Idempotency
- Mail ownership / authorization
- Folder validation
- Scheduled-send state machine
- Search filters
- HTML sanitization
- Tracking-pixel detection
- Retry/backoff
- Runtime settings validation

## Backend Integration Test

Gerçek PostgreSQL + test IMAP/SMTP server ile:

- Account connect/login
- Mail sync
- Send
- Draft
- Scheduled send
- Move/delete/archive
- Folder operations
- Attachment
- Session revoke

## Flutter Unit Test

- Repository state transitions
- API error mapping
- Offline mutation queue
- Token refresh logic
- Model serialization
- Search/filter state
- Compose state

## Flutter Widget Test

- Inbox
- Mail detail
- Compose
- Search
- Account switcher
- Folder picker
- Label picker
- Error/loading/empty states

## End-to-End / Integration Test

En kritik kullanıcı yolculukları:

1. Login → Inbox → Mail detail
2. Compose → Send → Sent folder
3. Reply → Send
4. Attachment → Send
5. Offline → Mutation → Reconnect
6. Multi-account → Unified inbox
7. Scheduled send
8. Undo send
9. Push notification → Mail detail
10. Session revoke

---

# 62. Release Öncesi Minimum Regression Paketi

Her release'te en az şu senaryolar çalıştırılmalı:

- [ ] **P0** Password login.
- [ ] **P0** OAuth login.
- [ ] **P0** Token refresh.
- [ ] **P0** Inbox sync.
- [ ] **P0** Mail detail.
- [ ] **P0** Read/unread.
- [ ] **P0** Move.
- [ ] **P0** Trash + restore.
- [ ] **P0** Compose + send.
- [ ] **P0** Duplicate-send/idempotency kontrolü.
- [ ] **P0** Attachment send.
- [ ] **P0** Draft recovery.
- [ ] **P0** Undo send.
- [ ] **P0** Scheduled send.
- [ ] **P0** Multi-account isolation.
- [ ] **P0** Offline cache.
- [ ] **P0** Offline queue + reconnect.
- [ ] **P0** Push notification.
- [ ] **P0** Session revoke.
- [ ] **P0** XSS sanitization.
- [ ] **P0** Tracking pixel blocking.
- [ ] **P0** Account ownership/authorization.
- [ ] **P0** Backend restart recovery.

---

# 63. İlk Aşamada Özellikle Test Edilmesi Gereken 15 Kritik Senaryo

Eğer zaman kısıtlıysa önce aşağıdaki senaryolara odaklanın:

1. **Mail send sırasında network timeout → retry → duplicate mail oluşmaması**
2. **Aynı `Idempotency-Key` ile paralel send → yalnız bir mail gönderilmesi**
3. **Access token expire → refresh → kullanıcının işlemine devam etmesi**
4. **Aynı anda iki request `401` → refresh race condition oluşmaması**
5. **Account A token ile Account B mailine erişilememesi**
6. **Offline mutation → reconnect → server ile doğru reconcile**
7. **Mail move/delete server tarafından reddedilince optimistic UI rollback**
8. **Undo send sırasında app kill → mail state'inin korunması**
9. **Scheduled send sırasında backend restart → duplicate send oluşmaması**
10. **DeliveryUnknown mailin otomatik resend edilmemesi**
11. **Draft sync fail → kullanıcının yazdığı içeriğin kaybolmaması**
12. **Attachment upload fail → yanlış “E-posta gönderildi” mesajı çıkmaması**
13. **HTML mail içindeki XSS/script payload'ın çalışmaması**
14. **Junk/DMARC-fail mail tracking pixel'larının yüklenmemesi**
15. **Multi-account unified inbox işlemlerinin yanlış hesaba uygulanmaması**

---

# 64. Bug Raporu Şablonu

```md
## Başlık

[Kısa ve net problem açıklaması]

## Öncelik

P0 / P1 / P2 / P3

## Ortam

- App version:
- Backend version/commit:
- Device:
- OS:
- Mail provider:
- Network:
- Account count:

## Ön Koşullar

1.
2.

## Adımlar

1.
2.
3.

## Beklenen Sonuç

...

## Gerçek Sonuç

...

## Tekrarlanma Oranı

Örn: 5/5, 2/10

## Log / Correlation ID

...

## Ekran Görüntüsü / Video

...
```

---

# 65. Test Case Şablonu

```md
### TC-MAIL-001 — Mail gönderme

**Öncelik:** P0

**Ön Koşullar**
- Kullanıcı login olmuş olmalı.
- SMTP bağlantısı çalışıyor olmalı.

**Adımlar**
1. Compose ekranını aç.
2. Geçerli bir alıcı gir.
3. Subject ve body gir.
4. Gönder butonuna bas.

**Beklenen Sonuç**
- Request bir kez gönderilmeli.
- Mail SMTP üzerinden gönderilmeli.
- Başarılı gönderim doğrulandıktan sonra success mesajı gösterilmeli.
- Mail Gönderilenler klasöründe görünmeli.
- Duplicate mail oluşmamalı.
```

---

# Sonuç

KaydetMail için en riskli alanlar klasik UI hatalarından ziyade **dağıtık state ve veri tutarlılığı** problemleridir. Özellikle aşağıdaki alanlar otomasyon kapsamına alınmalıdır:

- send idempotency,
- token refresh concurrency,
- offline queue/reconciliation,
- remote-first mutation rollback,
- multi-account data isolation,
- scheduled-send state machine,
- undo-send crash recovery,
- HTML/mail-content sanitization,
- session revocation,
- backend restart/recovery.

Bu alanlarda hata oluşması durumunda kullanıcı tarafında duplicate mail, veri kaybı, yanlış hesaptan işlem veya güvenlik problemi meydana gelebilir.
