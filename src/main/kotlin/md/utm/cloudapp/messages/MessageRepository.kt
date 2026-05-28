package md.utm.cloudapp.messages

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.support.GeneratedKeyHolder
import org.springframework.stereotype.Repository
import java.sql.PreparedStatement
import java.sql.Statement
import java.time.Instant

@Repository
class MessageRepository(private val jdbc: JdbcTemplate) {

    fun findAll(): List<Message> = jdbc.query(
        "SELECT id, text, created_at FROM messages ORDER BY id DESC"
    ) { rs, _ ->
        Message(
            id = rs.getLong("id"),
            text = rs.getString("text"),
            createdAt = rs.getTimestamp("created_at").toInstant(),
        )
    }

    fun insert(text: String): Message {
        val keyHolder = GeneratedKeyHolder()
        jdbc.update({ conn ->
            val ps: PreparedStatement = conn.prepareStatement(
                "INSERT INTO messages(text) VALUES (?)",
                Statement.RETURN_GENERATED_KEYS,
            )
            ps.setString(1, text)
            ps
        }, keyHolder)
        val id = (keyHolder.keys?.get("id") as? Number)?.toLong()
            ?: keyHolder.key?.toLong()
            ?: error("No generated key returned")
        return Message(id = id, text = text, createdAt = Instant.now())
    }
}
