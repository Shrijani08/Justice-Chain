package com.example.justice_chain

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** The Sakshya launcher face: opens the app and gets out of the way. */
class SakshyaFace : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }
}
