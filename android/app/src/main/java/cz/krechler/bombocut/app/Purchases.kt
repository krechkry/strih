// Ported from Bombocut/App/Purchases.swift (iOS ad3827a) on Google Play Billing. Same deal: 7 days with every
// tool, then one purchase (cz.krechler.bombocut.full, a one-time product) or the projects can still be exported
// as they are. Play has free trials only for subscriptions, so the trial start is kept on the phone (in the
// preferences Android Backup restores, so a reinstall on the same Google account doesn't start a new week).
package cz.krechler.bombocut.app

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object Purchases {
    const val fullID = "cz.krechler.bombocut.full"
    const val trialDays = 7
    private const val dayMs = 24L * 60 * 60 * 1000

    sealed class Access {
        data object Checking : Access()
        /** Never started the trial. */
        data object New : Access()
        data class Trial(val endsMs: Long) : Access()
        data object Expired : Access()
        data object Owned : Access()
    }

    private val _access = MutableStateFlow<Access>(Access.Checking)
    val access: StateFlow<Access> = _access
    private val _price = MutableStateFlow<String?>(null)
    val price: StateFlow<String?> = _price
    val busy = MutableStateFlow(false)
    val error = MutableStateFlow<String?>(null)

    private lateinit var prefs: SharedPreferences
    private var client: BillingClient? = null
    private var full: ProductDetails? = null
    /** CI and debug builds: the paywall stays out of the way unless asked for (iOS: Skip in Xcode builds). */
    var debugUnlocked = false

    val unlocked: Boolean get() = when (_access.value) {
        Access.Owned, is Access.Trial, Access.Checking -> true
        Access.New, Access.Expired -> false
    }

    val daysLeft: Int get() {
        val a = _access.value as? Access.Trial ?: return 0
        return maxOf(1, ((a.endsMs - System.currentTimeMillis() + dayMs - 1) / dayMs).toInt())
    }

    fun priceText(): String = _price.value ?: "149 Kč"

    fun init(context: Context) {
        prefs = context.getSharedPreferences("purchases", Context.MODE_PRIVATE)
        if (prefs.getBoolean("owned", false) || debugUnlocked) _access.value = Access.Owned else fromTrial()
        val c = BillingClient.newBuilder(context.applicationContext)
            .setListener(PurchasesUpdatedListener { r, list -> updated(r, list) })
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build()
        client = c
        c.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) { loadProduct(); refresh() }
            }
            override fun onBillingServiceDisconnected() {}
        })
    }

    private fun fromTrial() {
        if (debugUnlocked) { _access.value = Access.Owned; return }
        val start = prefs.getLong("trialStart", 0L)
        _access.value = when {
            start == 0L -> Access.New
            System.currentTimeMillis() < start + trialDays * dayMs -> Access.Trial(start + trialDays * dayMs)
            else -> Access.Expired
        }
    }

    /** The trial week starts now (nothing is bought). */
    fun startTrial() {
        if (prefs.getLong("trialStart", 0L) == 0L) prefs.edit().putLong("trialStart", System.currentTimeMillis()).apply()
        fromTrial()
    }

    /** A day passed while the app was open. */
    fun recheck() { if (_access.value is Access.Trial || _access.value == Access.Expired) fromTrial() }

    private fun loadProduct() {
        val c = client ?: return
        val params = QueryProductDetailsParams.newBuilder().setProductList(listOf(
            QueryProductDetailsParams.Product.newBuilder().setProductId(fullID).setProductType(BillingClient.ProductType.INAPP).build()
        )).build()
        c.queryProductDetailsAsync(params) { _, result ->
            full = result.productDetailsList.firstOrNull()
            full?.oneTimePurchaseOfferDetails?.formattedPrice?.let { _price.value = it }
        }
    }

    /** Owned on Google Play (a purchase on this account, also after a reinstall or on another phone). */
    fun refresh() {
        val c = client ?: return
        c.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()) { r, list ->
            if (r.responseCode == BillingClient.BillingResponseCode.OK) handle(list)
        }
    }

    fun buy(activity: Activity) {
        val c = client; val p = full
        if (c == null || p == null) { error.value = loc("The store isn't reachable right now. Try again in a moment."); return }
        busy.value = true
        val params = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(
            BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(p).build()
        )).build()
        val r = c.launchBillingFlow(activity, params)
        if (r.responseCode != BillingClient.BillingResponseCode.OK) busy.value = false
    }

    fun restore() { refresh() }

    private fun updated(r: BillingResult, list: List<Purchase>?) {
        busy.value = false
        when (r.responseCode) {
            BillingClient.BillingResponseCode.OK -> handle(list ?: emptyList())
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> refresh()
            BillingClient.BillingResponseCode.USER_CANCELED -> {}
            else -> error.value = r.debugMessage.ifEmpty { loc("The purchase didn't go through.") }
        }
    }

    private fun handle(list: List<Purchase>) {
        val p = list.firstOrNull { fullID in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED } ?: return
        if (!p.isAcknowledged) {
            client?.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(p.purchaseToken).build()) {}
        }
        prefs.edit().putBoolean("owned", true).apply()
        _access.value = Access.Owned
    }
}
