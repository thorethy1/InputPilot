package com.mkflabs.inputpilot.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.mkflabs.inputpilot.data.DeviceRepository
import com.mkflabs.inputpilot.data.StoredDeviceEntity
import com.mkflabs.inputpilot.network.DevicePresenceStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class DeviceDetailViewModel(
    private val repository: DeviceRepository,
    private val deviceId: String,
) : ViewModel() {
    private val _device = MutableStateFlow<StoredDeviceEntity?>(null)
    val device: StateFlow<StoredDeviceEntity?> = _device.asStateFlow()

    private val _displayName = MutableStateFlow("")
    val displayName: StateFlow<String> = _displayName.asStateFlow()

    private val _apiToken = MutableStateFlow("")
    val apiToken: StateFlow<String> = _apiToken.asStateFlow()

    private val _reachable = MutableStateFlow<Boolean?>(null)
    val reachable: StateFlow<Boolean?> = _reachable.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _deleted = MutableStateFlow(false)
    val deleted: StateFlow<Boolean> = _deleted.asStateFlow()

    val presence: StateFlow<DevicePresenceStatus> =
        combine(_device, _reachable) { device, reachable ->
            if (device == null) {
                DevicePresenceStatus.CHECKING
            } else {
                DevicePresenceStatus.resolve(
                    isReachable = reachable,
                    hasNetworkEndpoint = device.mdnsHost.isNotBlank() || !device.staIp.isNullOrBlank(),
                )
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DevicePresenceStatus.CHECKING)

    init {
        viewModelScope.launch {
            reload()
            refreshReachability()
        }
    }

    fun updateDisplayName(value: String) {
        _displayName.value = value
    }

    fun updateApiToken(value: String) {
        _apiToken.value = value
    }

    fun saveMeta() {
        viewModelScope.launch {
            val name = _displayName.value.trim()
            if (name.isNotEmpty()) repository.rename(deviceId, name)
            repository.updateApiToken(deviceId, _apiToken.value)
            reload()
        }
    }

    fun setJiggle(enabled: Boolean) {
        val current = _device.value ?: return
        viewModelScope.launch {
            try {
                repository.setJiggle(current, enabled)
                _reachable.value = true
                reload()
            } catch (e: Exception) {
                _error.value = e.message
            }
        }
    }

    fun delete() {
        viewModelScope.launch {
            repository.delete(deviceId)
            _deleted.value = true
        }
    }

    fun clearError() {
        _error.value = null
    }

    private suspend fun reload() {
        val d = repository.getAll().firstOrNull { it.deviceId == deviceId }
        _device.value = d
        if (d != null) {
            _displayName.value = d.displayName
            _apiToken.value = d.apiToken.orEmpty()
        }
    }

    private suspend fun refreshReachability() {
        val current = _device.value ?: return
        val failed = repository.refreshAll(listOf(current))
        _reachable.value = !failed.contains(deviceId)
        reload()
    }

    companion object {
        fun factory(
            repository: DeviceRepository,
            deviceId: String,
        ): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    DeviceDetailViewModel(repository, deviceId) as T
            }
    }
}
