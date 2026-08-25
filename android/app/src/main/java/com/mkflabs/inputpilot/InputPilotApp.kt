package com.mkflabs.inputpilot

import android.app.Application
import androidx.room.Room
import com.mkflabs.inputpilot.data.AppDatabase
import com.mkflabs.inputpilot.data.DeviceRepository
import com.mkflabs.inputpilot.discovery.AndroidNsdBrowser
import com.mkflabs.inputpilot.discovery.NsdBrowser
import com.mkflabs.inputpilot.network.OkHttpDeviceApiClient

class InputPilotApp : Application() {
    lateinit var database: AppDatabase
        private set
    lateinit var repository: DeviceRepository
        private set
    val apiClient by lazy { OkHttpDeviceApiClient() }

    fun nsdBrowser(): NsdBrowser = AndroidNsdBrowser(this)

    override fun onCreate() {
        super.onCreate()
        database =
            Room.databaseBuilder(this, AppDatabase::class.java, "inputpilot.db")
                .fallbackToDestructiveMigration()
                .build()
        repository = DeviceRepository(database.deviceDao(), apiClient)
    }
}
