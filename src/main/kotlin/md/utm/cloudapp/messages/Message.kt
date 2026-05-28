package md.utm.cloudapp.messages

import java.time.Instant

data class Message(
    val id: Long?,
    val text: String,
    val createdAt: Instant?,
)
