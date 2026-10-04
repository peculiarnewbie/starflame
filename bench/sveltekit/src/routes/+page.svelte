<script lang="ts">
  import { ping } from "#lib/todos.remote";
</script>

<p>{await ping(1)}</p>
