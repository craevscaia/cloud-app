package md.utm.cloudapp.messages

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.http.MediaType
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class MessagesControllerIT @Autowired constructor(
    private val mockMvc: MockMvc,
    private val jdbc: JdbcTemplate,
) {
    @BeforeEach
    fun setup() {
        jdbc.execute(
            "CREATE TABLE IF NOT EXISTS messages (" +
                "id BIGINT AUTO_INCREMENT PRIMARY KEY, " +
                "text VARCHAR(1000) NOT NULL, " +
                "created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)"
        )
        jdbc.execute("DELETE FROM messages")
    }

    @Test
    fun `POST then GET round-trips a message`() {
        mockMvc.perform(
            post("/messages")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"text":"hello"}""")
        )
            .andExpect(status().isCreated)
            .andExpect(jsonPath("$.text").value("hello"))
            .andExpect(jsonPath("$.id").isNumber)

        mockMvc.perform(get("/messages"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$[0].text").value("hello"))
    }

    @Test
    fun `POST with empty text returns 400`() {
        mockMvc.perform(
            post("/messages")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"text":""}""")
        ).andExpect(status().isBadRequest)
    }
}
